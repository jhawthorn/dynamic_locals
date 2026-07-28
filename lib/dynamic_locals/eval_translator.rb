require "dynamic_locals/base_translator"

module DynamicLocals
  # This is (probably) the simplest possible implementation of the behaviour we
  # want. It builds a new string of Ruby code with assignments to the locals
  # each time it is called and evals that string.
  #
  # This is not intended to be used in production code, but for debugging and
  # as a reference implementation.
  class EvalTranslator < BaseTranslator
    def translate
      # `eval` compiles its argument as a standalone program, which -- unlike a
      # method body -- has no implicit `begin`. Wrap the source in begin/end so a
      # method-body-style implicit rescue parses.
      body = "begin\n#{original_src}\nend"
      # The file/line arguments make errors report the line the source would
      # occupy had it been spliced in directly: the `begin` line lands one
      # line above the eval call, so source line N reports as call line + N.
      %{eval(#{locals_hash}.keys.map { |k| "\#{k} = #{locals_hash}[\#{k.inspect}];" }.join + #{body.inspect}, binding, __FILE__, __LINE__ - 1)}
    end
  end
end
