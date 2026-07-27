require "test_helper"

class DynamicLocalsTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::DynamicLocals::VERSION
  end
end

module CommonBehaviour
  RUN_METHOD = :__dynamic_locals_run

  def translator_options
    {}
  end

  def eval_with_locals(src, locals={})
    translator = self.class::Implementation.new(src, **translator_options)
    singleton_class.class_eval(translator.to_s(RUN_METHOD))
    send(RUN_METHOD, **locals)
  ensure
    singleton_class.remove_method(RUN_METHOD) if singleton_class.method_defined?(RUN_METHOD)
  end

  def assert_dynamic_result(expected, src, locals={})
    actual = eval_with_locals(src, locals)
    assert expected == actual, "Expected #{actual.inspect} to equal #{expected.inspect}"
  end

  def assert_dynamic_name_error(src, locals={}, name:)
    ex = assert_raises(NameError) do
      eval_with_locals(src, locals)
    end

    assert_match(/undefined (?:local variable or method|method) [`']#{Regexp.escape(name.to_s)}['`]/, ex.message)
  end

  def my_method_name(&block)
    :hi_from_my_method
  end

  def helper_value
    :from_helper
  end

  def default_value
    :from_default_helper
  end

  def rhs_value
    :from_rhs_helper
  end

  def numeric_value
    40
  end

  def test_no_variables
    assert_dynamic_result(2, "1+1")
  end

  def test_variable_access
    assert_dynamic_result(2, "foo", { foo: 2 })
  end

  def test_variable_access_preserves_object_identity
    object = Object.new
    assert eval_with_locals("foo", { foo: object }).equal?(object), "expected the same object, not a copy"
  end

  def test_variable_access_with_uninspectable_values
    assert_equal Float::INFINITY, eval_with_locals("foo", { foo: Float::INFINITY })
  end

  def test_mutations_are_visible_on_the_supplied_object
    array = []
    eval_with_locals("foo << :mutated", { foo: array })
    assert_equal [:mutated], array
  end

  def test_bare_read_matrix
    assert_dynamic_result(:from_local, "helper_value", { helper_value: :from_local })
    assert_dynamic_result(:from_helper, "helper_value", {})
    assert_dynamic_result(:from_helper, "helper_value", { unused: :ignored })
    assert_dynamic_name_error("missing_value", name: :missing_value)
  end

  def test_method_call
    assert_dynamic_result(:hi_from_my_method, "my_method_name", { foo: 2 })
  end

  def test_variable_access_shadowing_method
    assert_dynamic_result(:a_local, "my_method_name", { my_method_name: :a_local })
  end

  def test_method_call_parens
    assert_dynamic_result(:hi_from_my_method, "my_method_name()", { my_method_name: :a_local })
  end

  def test_method_call_self
    assert_dynamic_result(:hi_from_my_method, "self.my_method_name", { my_method_name: :a_local })
  end

  def test_method_call_block
    assert_dynamic_result(:hi_from_my_method, "my_method_name {}", { my_method_name: :a_local })
  end

  def test_variable_assignment
    assert_dynamic_result(123, "foo = 123; foo", { foo: 123 })
  end

  def test_or_assignment_undefined
    assert_dynamic_result(:default, "foo ||= :default; foo", {})
  end

  def test_or_assignment_nil
    assert_dynamic_result(:default, "foo ||= :default; foo", { foo: nil })
  end

  def test_or_assignment_with_value
    assert_dynamic_result(123, "foo ||= :default", { foo: 123 })
    assert_dynamic_result(123, "foo ||= :default; foo", { foo: 123 })
    assert_dynamic_result(123, "foo = 123; foo ||= :default; foo")
    assert_dynamic_result(123, "foo = 123; foo ||= :default; foo", { foo: 0 })
    assert_dynamic_result(123, "foo ||= bar", { bar: 123 })
  end

  def test_or_assignment_matrix
    assert_dynamic_result(:existing, "foo ||= missing_value; foo", { foo: :existing })
    assert_dynamic_result(:from_default_local, "foo ||= default_value; foo", { default_value: :from_default_local })
    assert_dynamic_result(:from_default_helper, "foo ||= default_value; foo", {})
    assert_dynamic_result(:from_default_helper, "foo ||= default_value; foo", { foo: nil })
    assert_dynamic_result(:from_default_helper, "foo ||= default_value; foo", { foo: false })
    assert_dynamic_result(:from_default_helper, "helper_value ||= default_value; helper_value", {})

    assert_dynamic_name_error("foo ||= missing_value", { foo: nil }, name: :missing_value)
  end

  def test_and_assignment
    assert_dynamic_result(:replacement, "foo &&= bar; foo", { foo: true, bar: :replacement })
    assert_dynamic_result(false, "foo &&= bar; foo", { foo: false, bar: :replacement })
  end

  def test_and_assignment_matrix
    assert_dynamic_result(:from_rhs_local, "foo &&= rhs_value; foo", { foo: true, rhs_value: :from_rhs_local })
    assert_dynamic_result(:from_rhs_helper, "foo &&= rhs_value; foo", { foo: true })
    assert_dynamic_result(false, "foo &&= missing_value; foo", { foo: false })
    assert_dynamic_result(nil, "foo &&= missing_value; foo", {})
    assert_dynamic_result(nil, "helper_value &&= rhs_value; helper_value", {})

    assert_dynamic_name_error("foo &&= missing_value; foo", { foo: true }, name: :missing_value)
  end

  def test_multiple_assignment
    assert_dynamic_result([1, 2], "foo, bar = values; [foo, bar]", { values: [1, 2] })
  end

  def test_call_then_assignment
    assert_dynamic_result(:hi_from_my_method, <<-RUBY)
      a = my_method_name
      my_method_name ||= my_method_name
      a
    RUBY
  end

  def test_read_before_assignment
    # Intentional divergence: the rewrite raises NoMethodError here where plain
    # Ruby raises NameError.
    assert_dynamic_name_error("foo; foo = 1", name: :foo)
    assert_dynamic_result(1, "foo; foo = 1", { foo: 99 })
    assert_dynamic_result(:from_helper, "a = helper_value; helper_value = 1; a")
    assert_dynamic_result(99, "a = helper_value; helper_value = 1; a", { helper_value: 99 })
  end

  def test_assignment_with_existing_value
    assert_dynamic_result(123, "foo = foo + 100", { foo: 23 })
    assert_dynamic_result(123, "foo += 100", { foo: 23 })

    assert_dynamic_result(123, "foo = nil if false; foo", { foo: 123 })
    assert_dynamic_result(123, "if false; foo = nil; end; foo", { foo: 123 })
  end

  def test_arithmetic_assignment_matrix
    assert_dynamic_result(41, "foo = numeric_value + 1; foo", {})
    assert_dynamic_result(6, "foo = numeric_value + 1; foo", { numeric_value: 5 })
    assert_dynamic_result(6, "foo = foo + numeric_value; foo", { foo: 1, numeric_value: 5 })
    assert_dynamic_result(3, "foo += 1; foo", { foo: 2 })

    assert_raises(NoMethodError) do
      eval_with_locals("numeric_value += 1; numeric_value")
    end
  end

  def test_multiline_rewrites
    src = <<~RUBY
      three = one + two
      one + three + eight
    RUBY

    assert_dynamic_result(12, src, { one: 1, two: 2, eight: 8 })
  end

  def test_multibyte_offsets_before_rewrite
    src = <<~RUBY
      emoji = :🎃
      greeting
    RUBY

    assert_dynamic_result("Hello", src, { greeting: "Hello" })
  end

  def test_defined
    assert_dynamic_result(nil, "defined?(foo)", { })
    assert_dynamic_result("local-variable", "defined?(foo)", { foo: 123 })

    assert_dynamic_result("method", "defined?(my_method_name)", { })
    assert_dynamic_result("local-variable", "defined?(my_method_name)", { my_method_name: 123 })

    assert_dynamic_result("local-variable", "defined? foo", { foo: 123 })
    assert_dynamic_result("method", "defined? my_method_name", { })

    assert_dynamic_result("method", "defined?(my_method_name())", { my_method_name: 123 })
    assert_dynamic_result("method", "defined?(self.my_method_name)", { my_method_name: 123 })
  end

  def test_defined_matrix
    assert_dynamic_result("local-variable", "defined?(helper_value)", { helper_value: :from_local })
    assert_dynamic_result("local-variable", "defined?(helper_value)", { helper_value: nil })
    assert_dynamic_result("method", "defined?(helper_value)", {})
    assert_dynamic_result(nil, "defined?(missing_value)", {})
    assert_dynamic_result(nil, "result = defined?(assigned_later); assigned_later = 1; result", {})
    assert_dynamic_result("local-variable", "result = defined?(assigned_later); assigned_later = 1; result", { assigned_later: 123 })
    assert_dynamic_result("method", "defined?(helper_value())", { helper_value: :from_local })
    assert_dynamic_result("method", "defined?(self.helper_value)", { helper_value: :from_local })
  end

  def test_defined_supplied_local_is_nil
    assert_dynamic_result("local-variable", "defined?(foo)", { foo: nil })
  end

  def test_defined_locally_assigned_name
    assert_dynamic_result("local-variable", "foo = 1; defined?(foo)", {})
  end

  def test_defined_assignment_expression
    assert_dynamic_result("assignment", "defined?(foo = 1)", {})
    assert_dynamic_result(nil, "defined?(foo = 1); foo", {})
  end

  def test_defined_operator_expression
    assert_dynamic_result("method", "defined?(foo + 1)", { foo: 2 })
    assert_dynamic_result(nil, "defined?(foo + 1)", {})
    assert_dynamic_result("method", "defined?(numeric_value + 1)", {})
  end

  def test_defined_instance_variable
    assert_dynamic_result(nil, "defined?(@x)", {})
  end

  def test_defined_compound_expression_with_ambiguous_names
    skip "pending: rewritten reads make defined? see a defined compound expression"

    assert_dynamic_result(nil, "defined?([*a])")
    assert_dynamic_result("expression", "defined?([*a])", { a: [1] })
    assert_dynamic_result(nil, "defined?(itself(*a))")
    assert_dynamic_result("method", "defined?(itself(*a))", { a: [] })
  end

  def test_local_variables_reflection
    skip "pending: translation artifacts are visible to local_variables"

    assert_dynamic_result([:x], "x = 1; local_variables.sort")
    assert_dynamic_result([:x, :y], "x = 1; local_variables.sort", { y: 2 })
  end

  def test_dynamic_locals_inside_blocks
    assert_dynamic_result([123], "[1].map { foo }", { foo: 123 })
    assert_dynamic_result([3], "[1].map { |one| one + two }", { two: 2 })
    assert_dynamic_result([1], "[1].map { |foo| foo }", { foo: 123 })
  end

  def test_dynamic_locals_inside_lambdas
    assert_dynamic_result(123, "-> { foo }.call", { foo: 123 })
  end

  def test_block_assignment_captures_supplied_dynamic_outer_local
    assert_equal :changed, eval_with_locals("[1].each { helper_value = :changed }; helper_value", { helper_value: :original })
  end

  def test_block_assignment_does_not_leak_when_dynamic_outer_local_is_omitted
    assert_equal :from_helper, eval_with_locals("[1].each { helper_value = :changed }; helper_value")
  end

  def test_omitted_dynamic_outer_local_does_not_make_block_assignment_capture_between_yields
    assert_equal [[1, 1], :from_helper], eval_with_locals("[[1, 2].map { helper_value ||= 0; helper_value += 1 }, helper_value]")
  end

  def test_block_assignment_uses_supplied_dynamic_outer_local_without_outer_read
    assert_equal [6, 7], eval_with_locals("[1, 2].map { numeric_value += 1 }", { numeric_value: 5 })
  end

  def test_omitted_dynamic_outer_local_stays_nested_local_without_outer_read
    assert_equal [1, 1], eval_with_locals("[1, 2].map { helper_value ||= 0; helper_value += 1 }")
  end

  def test_block_operator_assignment_captures_supplied_dynamic_outer_local
    assert_equal 6, eval_with_locals("[1].each { numeric_value += 1 }; numeric_value", { numeric_value: 5 })
  end

  def test_block_or_assignment_captures_supplied_dynamic_outer_local
    assert_equal :changed, eval_with_locals("[1].each { helper_value ||= :changed }; helper_value", { helper_value: nil })
    assert_equal :original, eval_with_locals("[1].each { helper_value ||= :changed }; helper_value", { helper_value: :original })
  end

  def test_lambda_assignment_captures_supplied_dynamic_outer_local
    assert_equal :changed, eval_with_locals("-> { helper_value = :changed }.call; helper_value", { helper_value: :original })
  end

  def test_omitted_dynamic_outer_local_does_not_make_lambda_assignment_capture_between_calls
    assert_equal [1, 1, :from_helper], eval_with_locals("l = -> { helper_value ||= 0; helper_value += 1 }; [l.call, l.call, helper_value]")
  end

  def test_block_parameter_shadows_dynamic_outer_local
    assert_equal [[1], :outer], eval_with_locals("[[1].map { |helper_value| helper_value }, helper_value]", { helper_value: :outer })
  end

  def test_block_local_declaration_shadows_dynamic_outer_local
    assert_equal [[1], :outer], eval_with_locals("[[1].map { |x; helper_value| helper_value = x; helper_value }, helper_value]", { helper_value: :outer })
  end

  def test_block_local_declaration_prevents_omitted_dynamic_outer_local_capture_between_yields
    assert_equal [[1, 1], :from_helper], eval_with_locals("[[1, 2].map { |x; helper_value| helper_value ||= 0; helper_value += 1 }, helper_value]")
  end

  def test_block_only_assignment_gets_fresh_binding_per_invocation
    src = "[1, 2, 3].map { |x| v = x; -> { v } }.map(&:call)"

    assert_equal [3, 3, 3], eval_with_locals(src, { v: 0 })
    assert_equal [1, 2, 3], eval_with_locals(src)
  end

  def test_block_assignment_stays_block_local_when_outer_assignment_is_later
    src = "1.times { x = 1 }\nx = 5 if false\nx"

    assert_equal 1, eval_with_locals(src, { x: 99 })
    # When omitted, `x` is not yet an outer local where the block is parsed, so
    # the assignment stays block-local and the trailing read is nil.
    assert_nil eval_with_locals(src)
  end

  def test_block_multiple_assignment
    src = "[1].map { a, b = [1, 2]; a + b }"
    assert_equal [3], eval_with_locals(src)
    assert_equal [3], eval_with_locals(src, { a: 9, b: 9 })
  end

  def test_block_multiple_assignment_captures_supplied_dynamic_outer_local
    assert_equal 1, eval_with_locals("[1].each { a, b = [1, 2] }; a", { a: 0 })
  end

  def test_block_multiple_assignment_stays_block_local_when_omitted
    assert_dynamic_name_error("[1].each { a, b = [1, 2] }; a", name: :a)
  end

  def test_block_multiple_assignment_with_splat_and_nesting
    src = "[1].map { a, *b, (c, d) = [1, 2, 3, [4, 5]]; [a, b, c, d] }.first"
    assert_equal [1, [2, 3], 4, 5], eval_with_locals(src)
    assert_equal [1, [2, 3], 4, 5], eval_with_locals(src, { a: 9, c: 9 })
  end

  def test_block_rescue_reference
    src = "[1].map { begin; raise 'boom'; rescue => e; e.message; end }"
    assert_equal ["boom"], eval_with_locals(src)
    assert_equal ["boom"], eval_with_locals(src, { e: nil })
  end

  def test_block_rescue_reference_captures_supplied_dynamic_outer_local
    assert_equal "boom", eval_with_locals("[1].each { begin; raise 'boom'; rescue => e; end }; e.message", { e: nil })
  end

  def test_block_rescue_reference_stays_block_local_when_omitted
    assert_dynamic_name_error("[1].each { begin; raise 'boom'; rescue => e; end }; e", name: :e)
  end

  def test_for_loop_inside_block
    src = "[1].map { total = 0; for v in [1, 3]; total += v; end; total + v }"
    assert_equal [7], eval_with_locals(src)
    assert_equal [7], eval_with_locals(src, { total: 9, v: 9 })
  end

  def test_for_loop_index_inside_block_captures_supplied_dynamic_outer_local
    assert_equal 2, eval_with_locals("[1].each { for v in [1, 2]; end }; v", { v: 0 })
  end

  def test_for_loop_index_inside_block_stays_block_local_when_omitted
    assert_dynamic_name_error("[1].each { for v in [1, 2]; end }; v", name: :v)
  end

  def test_assignment_in_numbered_parameter_block
    src = "[1].map { v = _1; v + one }"
    assert_equal [2], eval_with_locals(src, { one: 1 })
    assert_equal [2], eval_with_locals(src, { one: 1, v: 9 })
  end

  def test_assignment_in_it_parameter_block
    skip "the `it` block parameter requires Ruby 3.4+" if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.4")

    src = "[1].map { v = it; v + one }"
    assert_equal [2], eval_with_locals(src, { one: 1 })
    assert_equal [2], eval_with_locals(src, { one: 1, v: 9 })
  end

  def test_regexp_named_capture_in_block
    src = '["hi"].map { |s| /(?<word>\w+)/ =~ s; word }'
    assert_equal ["hi"], eval_with_locals(src)
    assert_equal ["hi"], eval_with_locals(src, { word: :outer })
  end

  def test_regexp_named_capture_in_block_captures_supplied_dynamic_outer_local
    assert_equal "hi", eval_with_locals('["hi"].each { |s| /(?<word>\w+)/ =~ s }; word', { word: nil })
  end

  def test_regexp_named_capture_in_block_stays_block_local_when_omitted
    assert_dynamic_name_error('["hi"].each { |s| /(?<word>\w+)/ =~ s }; word', name: :word)
  end

  def test_regexp_named_capture_as_condition
    src = '["hi", "!!"].map { |s| if /(?<word>\w+)/ =~ s then word else :none end }'
    assert_equal ["hi", :none], eval_with_locals(src)
    assert_equal ["hi", :none], eval_with_locals(src, { word: :outer })
  end

  def test_regexp_match_expression_value_preserved
    src = '["hi"].map { |s| idx = (/(?<word>\w+)/ =~ s); [idx, word] }.first'
    assert_equal [0, "hi"], eval_with_locals(src)
    assert_equal [0, "hi"], eval_with_locals(src, { idx: 9, word: :outer })
  end

  def test_regexp_named_capture_at_root
    src = '/(?<word>\w+)/ =~ str; word'
    assert_equal "hi", eval_with_locals(src, { str: "hi" })
    assert_equal "hi", eval_with_locals(src, { str: "hi", word: :outer })
    assert_nil eval_with_locals(src, { str: "!!" })
  end

  def test_regexp_named_capture_at_root_with_block_assignment
    src = '1.times { word = :from_block }; /(?<word>\w+)/ =~ str; word'
    assert_equal "hi", eval_with_locals(src, { str: "hi" })
    assert_equal "hi", eval_with_locals(src, { str: "hi", word: :outer })
  end

  def test_block_local_keeps_per_activation_binding_across_reentrancy
    src = "f = ->(n) { x = n; f.(n - 1) if n > 0; x }; f.(3)"

    assert_equal 0, eval_with_locals(src, { x: 99 })
    assert_equal 3, eval_with_locals(src)
  end

  def test_pattern_match_pin_uses_dynamic_local
    assert_dynamic_result(:matched, "case numeric_value; in ^foo then :matched; else :no; end", { foo: 40 })
    assert_dynamic_result([:matched], "[1].map { case numeric_value; in ^foo then :matched; else :no; end }", { foo: 40 })
  end

  def test_pattern_capture_then_pin_in_same_clause
    skip "pending"
    # The pin reads the block-local shadow, which only syncs at the clause
    # body, so mid-pattern it raises NameError.
    assert_dynamic_result([:matched], "[1].map { case [0, 0]; in [a, ^a] then :matched; else :no; end }")
  end

  def test_block_pattern_targets_preserve_dynamic_or_nested_scope
    cases = [
      ["[1, 2].map { |value| value => x; -> { x } }.map(&:call)", { x: 0 }, [2, 2], [1, 2]],
      ["[1, 2].map { |value| value in x; -> { x } }.map(&:call)", { x: 0 }, [2, 2], [1, 2]],
      ["[{ x: 1 }, { x: 2 }].map { |value| value => { x: }; -> { x } }.map(&:call)", { x: 0 }, [2, 2], [1, 2]],
      ["[[1, 2], [3, 4]].map { |value| value => [*x]; -> { x } }.map(&:call)", { x: [] }, [[3, 4], [3, 4]], [[1, 2], [3, 4]]],
    ]

    cases.each do |src, locals, shared, fresh|
      assert_equal shared, eval_with_locals(src, locals)
      assert_equal fresh, eval_with_locals(src)
    end
  end

  def test_block_in_clause_targets_preserve_dynamic_or_nested_scope
    sources = [
      "[1, 2].map { |value| case value; in x if x > 0 then -> { x }; end }.map(&:call)",
      "[1, 2].map { |value| case value; in x unless x < 1 then -> { x }; end }.map(&:call)",
    ]

    sources.each do |src|
      assert_equal [2, 2], eval_with_locals(src, { x: 0 })
      assert_equal [1, 2], eval_with_locals(src)
    end
  end

  def test_pattern_target_inside_in_clause_guard_has_its_own_sync_point
    src = "[1, 2].map { |value| case value; in x if [x] in [y] then -> { [x, y] }; end }.map(&:call)"

    assert_equal [[2, 2], [2, 2]], eval_with_locals(src, { x: 0, y: 0 })
    assert_equal [[1, 1], [2, 2]], eval_with_locals(src)
  end

  def test_failed_block_pattern_predicate_does_not_assign
    assert_equal :outer, eval_with_locals("[1].each { [] in [x] }; x", { x: :outer })
    assert_dynamic_name_error("[1].each { [] in [x] }; x", name: :x)
  end

  def test_in_clause_target_is_assigned_before_a_failing_guard
    src = "[1].map { case 1; in x if false; else; end; x }"

    assert_equal [1], eval_with_locals(src, { x: :outer })
    assert_equal [1], eval_with_locals(src)
  end

  def test_method_body_implicit_rescue
    skip "this is probably nonsense"
    assert_dynamic_result(:rescued, "raise 'boom'\nrescue\n:rescued")
  end

  def test_method_definitions_do_not_capture_dynamic_locals
    ex = assert_raises(NameError) do
      eval_with_locals("def self.__dynamic_locals_method_probe; foo; end; __dynamic_locals_method_probe", { foo: 123 })
    end

    assert_match(/undefined local variable or method [`']foo['`]/, ex.message)
  end

  def test_binding
    assert_instance_of Binding, eval_with_locals("binding", { foo: 123 })
    assert_dynamic_result(5, "binding", { binding: 5 })
  end

  def test_binding_sees_current_values_of_assigned_locals
    assert_dynamic_result(1, "x = 1; binding.local_variable_get(:x)", { x: 99 })
    assert_dynamic_result(1, "x = 1; binding; x", { x: 99 })
  end

  def test_defined_binding
    assert_dynamic_result("method", "defined?(binding)")
    assert_dynamic_result("local-variable", "defined?(binding)", { binding: 5 })
    assert_dynamic_result(true, "defined?(binding); binding.is_a?(Binding)")
  end

  def test_raises_nameerror
    assert_dynamic_name_error("undefined_method_or_local", name: :undefined_method_or_local)
  end

  def test_unicode
    assert_dynamic_result(:🎃, ":🎃")
    assert_dynamic_result(:🎃, "(:🎃)")
    assert_dynamic_result(:🎃, "( :🎃 )")
    assert_dynamic_result("Hello", "🎃", 🎃: "Hello")
    assert_dynamic_result("Hello", "(🎃)", 🎃: "Hello")
    assert_dynamic_result("Hello", "( 🎃 )", 🎃: "Hello")
  end
end

class EvalTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::EvalTranslator

  def test_binding_reflects_supplied_locals
    assert_dynamic_result(true, "binding.local_variables.include?(:foo)", { foo: 123 })
    assert_dynamic_result(123, "binding.local_variable_get(:foo)", { foo: 123 })
    assert_dynamic_result(123, "binding.eval('foo')", { foo: 123 })
  end
end

class RewriteTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::RewriteTranslator

  def test_syntax_errors_are_raised_at_translate_time
    assert_raises(SyntaxError) do
      Implementation.new("def").translate
    end
  end

  def test_dynamic_pin_inside_nested_method_remains_a_syntax_error
    src = "def nested; case 1; in ^foo then :matched; end; end"

    assert_raises(SyntaxError) do
      Implementation.new(src).translate
    end
  end

  def test_custom_locals_hash_name
    dynamic = Implementation.new("foo + bar", locals_hash: :view_locals).translate

    assert_equal 5, eval("view_locals = { foo: 2, bar: 3 }; #{dynamic}")
  end

  def test_known_locals_assigned_in_body_are_left_untouched
    src = "rest = [dyn] if rest.empty?\nrest"

    translator = Implementation.new(src, known_locals: [:rest])
    singleton_class.class_eval("def #{RUN_METHOD}(locals, *rest)\n#{translator.translate}\nend")
    assert_equal [1, 2], send(RUN_METHOD, {}, 1, 2)
    assert_equal [:supplied], send(RUN_METHOD, { dyn: :supplied })
    singleton_class.remove_method(RUN_METHOD)

    translator = Implementation.new(src, lookup_strategy: :keywords, known_locals: [:rest])
    assert_equal "dyn: (__dynamic_locals_unset_0 = true; nil)", translator.keyword_parameters
    singleton_class.class_eval("def #{RUN_METHOD}(*rest, #{translator.keyword_parameters})\n#{translator.translate}\nend")
    assert_equal [1, 2], send(RUN_METHOD, 1, 2)
    assert_equal [:supplied], send(RUN_METHOD, dyn: :supplied)
  ensure
    singleton_class.remove_method(RUN_METHOD) if singleton_class.method_defined?(RUN_METHOD)
  end

end

class KeywordRewriteTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::RewriteTranslator

  def translator_options
    { lookup_strategy: :keywords }
  end

  def test_keyword_parameters
    translator = Implementation.new("foo + bar", **translator_options)

    assert_equal "bar: (__dynamic_locals_unset_0 = true; nil), foo: (__dynamic_locals_unset_1 = true; nil)", translator.keyword_parameters
    assert_equal "bar: (__dynamic_locals_unset_0 = true; nil), foo: (__dynamic_locals_unset_1 = true; nil), **rest", translator.keyword_parameters(rest: :rest)
  end

end
