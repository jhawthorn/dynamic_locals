# frozen_string_literal: true
#
# Compiles Ruby's bootstraptest (btest) cases into DynamicLocals methods and
# runs them, to find source constructs the local-variable rewriting mishandles.
#
# For each btest assertion we take its test source and:
#
#   1. BASELINE  - wrap the *unmodified* source in a plain method and run it.
#   2. DYNAMIC   - wrap the *translated* source (keyword strategy) in a method
#                  and run it, called with no locals.
#
# The btest's own `expected` value is the ground truth. Comparing DYNAMIC
# against BASELINE (rather than only against `expected`) lets us separate two
# very different situations:
#
#   * BASELINE already diverges from `expected`  -> the case simply can't be
#     represented as a method body (top-level return, BEGIN/END, __method__,
#     definee scope, ...). Not our bug -> reported as "unwrappable" and skipped.
#
#   * BASELINE matches but DYNAMIC differs (or crashes) -> the rewriting changed
#     behavior. This is the signal we care about -> reported as a failure.
#
# Usage:
#   bundle exec ruby test/btest_runner.rb [FILE_OR_GLOB ...]
#
#   With no arguments, runs every bootstraptest/test_*.rb found under RUBY_DIR.
#
# Environment:
#   RUBY_DIR     Ruby checkout to find bootstraptest/ in   (default: ../ruby)
#   BTEST_RUBY   ruby used to *run* compiled programs       (default: this ruby)
#   BTEST_TIMEOUT   per-program timeout in seconds          (default: 10)
#   STRATEGY     :keywords or :hash                         (default: keywords)
#   SHOW_SRC     if set, print the translated source for each failure
#   VERBOSE      if set, also list unwrappable/skipped cases

require "bundler/setup" rescue nil
$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "dynamic_locals"

require "open3"
require "tempfile"
require "rbconfig"

module BTest
  RUBY_DIR    = ENV.fetch("RUBY_DIR", File.expand_path("../../../ruby", __FILE__))
  RUN_RUBY    = ENV.fetch("BTEST_RUBY", RbConfig.ruby)
  TIMEOUT     = Integer(ENV.fetch("BTEST_TIMEOUT", "10"))
  STRATEGY    = ENV.fetch("STRATEGY", "keywords").to_sym
  METHOD_NAME = :__dynamic_locals_btest__
  REST_KW     = :__dynamic_locals_unused_keywords

  Result = Struct.new(:stdout, :stderr, :status, :timeout, keyword_init: true) do
    # "ok" == a clean exit, the way btest treats a successful run.
    def ok?
      !timeout && status&.success? && !status.signaled?
    end

    def crash_desc
      return "timeout" if timeout
      return "SIG#{Signal.list.invert[status.termsig] || status.termsig}" if status&.signaled?
      return "exit #{status.exitstatus}" unless status&.success?
      nil
    end
  end

  # A single collected assertion from a btest file.
  Assertion = Struct.new(:kind, :expected, :src, :file, :lineno, keyword_init: true)

  # Records the top-level assert_* calls in a btest file without running them.
  class Collector
    attr_reader :assertions

    def initialize(file)
      @file = file
      @assertions = []
    end

    def collect
      instance_eval(File.read(@file), @file)
      @assertions
    end

    def assert_equal(expected, src, *_ignored, **_kw)
      record(:equal, expected, src)
    end

    def assert_match(pattern, src, *_ignored, **_kw)
      record(:match, pattern, src)
    end

    def assert_not_match(pattern, src, *_ignored, **_kw)
      record(:not_match, pattern, src)
    end

    def assert_normal_exit(src, *_ignored, **_kw)
      record(:normal_exit, nil, src)
    end

    def assert_finish(_seconds, src, *_ignored, **_kw)
      record(:finish, nil, src)
    end

    # Syntax-level assertions aren't about runtime local behavior; skip them.
    def assert_valid_syntax(*) = nil
    def assert_syntax_error(*) = nil

    # btest files occasionally reference these helpers at load time.
    def flunk(*) = nil
    def skip(*) = nil

    # Swallow anything else a file might call at the top level.
    def method_missing(*) = nil
    def respond_to_missing?(*) = true

    private

    def record(kind, expected, src)
      lineno = caller_locations(2, 1).first&.lineno
      @assertions << Assertion.new(kind: kind, expected: expected, src: src, file: @file, lineno: lineno)
    end
  end

  # Wraps source in a method and runs it, mirroring btest's make_srcfile driver.
  class Program
    PREAMBLE = <<~RUBY
      class BT_Skip < Exception; end
      def skip(msg) = raise(BT_Skip, msg.to_s)
    RUBY

    def self.run(method_def, timeout: TIMEOUT)
      program = +PREAMBLE
      program << method_def << "\n"
      program << "print(begin; #{METHOD_NAME}; rescue BT_Skip; $!.message; end)\n"
      execute(program, timeout)
    end

    def self.execute(program, timeout)
      file = Tempfile.new(["btest_dl", ".rb"])
      file.write(program)
      file.close

      stdout = stderr = nil
      status = nil
      timed_out = false

      Open3.popen3(RUN_RUBY, "-W0", file.path) do |stdin, out, err, wait_thr|
        stdin.close
        out_reader = Thread.new { out.read }
        err_reader = Thread.new { err.read }

        if wait_thr.join(timeout)
          status = wait_thr.value
        else
          timed_out = true
          begin
            Process.kill("KILL", wait_thr.pid)
          rescue Errno::ESRCH
          end
          status = wait_thr.value
        end

        stdout = out_reader.value
        stderr = err_reader.value
      end

      Result.new(stdout: stdout, stderr: stderr, status: status, timeout: timed_out)
    ensure
      file&.unlink
    end
  end

  # Categories, ordered from most to least interesting.
  CATEGORIES = %i[translate_error fail_crash fail_mismatch unwrappable pass unsupported]

  class Runner
    def initialize(assertion)
      @a = assertion
    end

    # Returns [category, detail_hash]
    def run
      method_def = translated_method_def
      dynamic = Program.run(method_def)

      baseline = Program.run(baseline_method_def)

      # If the plain method wrapping already can't reproduce the expected
      # result, this case isn't representable as a method body -> not our bug.
      unless baseline_matches?(baseline)
        return [:unwrappable, { baseline: baseline }]
      end

      if !dynamic.ok?
        return [:fail_crash, { dynamic: dynamic, baseline: baseline, method_def: method_def }]
      end

      if dynamic_matches?(dynamic, baseline)
        [:pass, {}]
      else
        [:fail_mismatch, { dynamic: dynamic, baseline: baseline, method_def: method_def }]
      end
    rescue SyntaxError, StandardError => e
      [:translate_error, { error: e }]
    end

    private

    def translated_method_def
      translator = DynamicLocals::RewriteTranslator.new(@a.src, lookup_strategy: STRATEGY)
      params =
        if STRATEGY == :keywords
          translator.keyword_parameters(rest: REST_KW)
        else
          "#{translator.locals_hash} = {}"
        end
      "def #{METHOD_NAME}(#{params})\n#{translator.translate}\nend"
    end

    def baseline_method_def
      "def #{METHOD_NAME}\n#{@a.src}\nend"
    end

    # Does the BASELINE run reproduce the assertion's expectation?
    def baseline_matches?(result)
      compare(result)
    end

    # Does DYNAMIC agree with BASELINE (and still satisfy the assertion)?
    def dynamic_matches?(dynamic, baseline)
      case @a.kind
      when :normal_exit, :finish
        # Output is irrelevant (and often nondeterministic); a clean run is enough.
        dynamic.ok?
      else
        dynamic.stdout == baseline.stdout && compare(dynamic)
      end
    end

    def compare(result)
      return false unless result.ok?

      case @a.kind
      when :equal      then result.stdout == @a.expected
      when :match      then @a.expected =~ result.stdout ? true : false
      when :not_match  then @a.expected !~ result.stdout
      when :normal_exit, :finish then true
      else false
      end
    end
  end

  # Live one-character progress markers, printed as each assertion finishes.
  PROGRESS_CHAR = {
    pass:            ".",
    unwrappable:     "-",
    unsupported:     " ",
    fail_mismatch:   "F",
    fail_crash:      "C",
    translate_error: "E",
  }.freeze

  class Reporter
    def initialize
      @tally = Hash.new(0)
      @failures = []
    end

    def record(assertion, category, detail)
      @tally[category] += 1
      @current[category] += 1
      if %i[translate_error fail_crash fail_mismatch].include?(category)
        @failures << [assertion, category, detail]
      elsif category == :unwrappable && ENV["VERBOSE"]
        @failures << [assertion, category, detail]
      end
      tick(assertion, category, detail)
    end

    # Announce a file before its (potentially slow) run begins.
    def start_file(file, count)
      @current = Hash.new(0)
      if ENV["VERBOSE"]
        puts "\n#{File.basename(file)} (#{count} assertions)"
      else
        printf("  %-24s ", File.basename(file))
      end
      $stdout.flush
    end

    # Print live feedback as each assertion completes.
    def tick(assertion, category, detail)
      if ENV["VERBOSE"]
        loc = "#{File.basename(assertion.file)}:#{assertion.lineno}"
        line = "    %-16s %-11s %s" % [category, assertion.kind, loc]
        extra = one_line(detail)
        line += "  #{extra}" if extra
        puts line
      else
        print(PROGRESS_CHAR.fetch(category, "?"))
      end
      $stdout.flush
    end

    def finish_file
      counts = CATEGORIES.map { |c| "#{c}=#{@current[c]}" if @current[c] > 0 }.compact
      if ENV["VERBOSE"]
        puts "  => #{counts.join(' ')}"
      else
        puts "  #{counts.join(' ')}"
      end
      $stdout.flush
    end

    def print_failures
      return if @failures.empty?
      puts "\n" + ("=" * 72)
      puts "DETAILS"
      puts("=" * 72)
      @failures.each do |assertion, category, detail|
        loc = "#{File.basename(assertion.file)}:#{assertion.lineno}"
        puts "\n[#{category}] #{loc}  (#{assertion.kind})"
        puts indent(assertion.src.strip, "  | ")
        case category
        when :translate_error
          puts "  -> translate raised #{detail[:error].class}: #{detail[:error].message.lines.first&.strip}"
        when :fail_crash
          puts "  -> dynamic crashed: #{detail[:dynamic].crash_desc}"
          err = detail[:dynamic].stderr.to_s.strip
          puts indent(err.lines.first(4).join, "  ! ") unless err.empty?
        when :fail_mismatch
          puts "  -> expected #{fmt(assertion.expected)}"
          puts "     baseline #{fmt(detail[:baseline].stdout)}"
          puts "     dynamic  #{fmt(detail[:dynamic].stdout)}"
        end
        if ENV["SHOW_SRC"] && detail[:method_def]
          puts indent(detail[:method_def], "  ~ ")
        end
      end
    end

    def print_summary
      puts "\n" + ("=" * 72)
      total = @tally.values.sum
      puts "TOTAL #{total} assertions across #{@tally.inspect}"
      real = @tally[:fail_mismatch] + @tally[:fail_crash] + @tally[:translate_error]
      puts "Interesting (potential dynamic_locals bugs): #{real}"
    end

    private

    # A compact, single-line result summary for verbose mode.
    def one_line(detail)
      if detail[:error]
        "#{detail[:error].class}: #{detail[:error].message.lines.first&.strip}"
      elsif detail[:dynamic]&.crash_desc
        detail[:dynamic].crash_desc
      end
    end

    def fmt(str)
      s = str.is_a?(Regexp) ? str.source : str.to_s
      s = s.length > 200 ? s[0, 200] + "..." : s
      s.inspect
    end

    def indent(text, prefix)
      text.to_s.lines.map { |l| prefix + l.chomp }.join("\n")
    end
  end

  def self.btest_files(args)
    if args.empty?
      Dir.glob(File.join(RUBY_DIR, "bootstraptest", "test_*.rb")).sort
    else
      args.flat_map { |a| File.file?(a) ? [a] : Dir.glob(a) }.sort
    end
  end

  def self.main(args)
    files = btest_files(args)
    if files.empty?
      abort "No btest files found. Set RUBY_DIR or pass file paths."
    end

    puts "Compiling btests -> DynamicLocals (#{STRATEGY} strategy)"
    puts "  running with: #{RUN_RUBY}"
    puts "  files: #{files.size}"
    puts

    reporter = Reporter.new
    files.each do |file|
      assertions = Collector.new(file).collect
      reporter.start_file(file, assertions.size)
      assertions.each do |assertion|
        category, detail = Runner.new(assertion).run
        reporter.record(assertion, category, detail)
      end
      reporter.finish_file
    end

    reporter.print_failures
    reporter.print_summary
  end
end

BTest.main(ARGV) if $PROGRAM_NAME == __FILE__
