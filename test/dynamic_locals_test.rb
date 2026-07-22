require "test_helper"

class DynamicLocalsTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::DynamicLocals::VERSION
  end
end

module CommonBehaviour
  def eval_with_locals(src, locals={})
    dynamic = self.class::Implementation.new(src).translate
    dynamic = "locals = (#{locals.inspect});#{dynamic}"
    eval(dynamic)
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

  def test_bare_read_matrix
    assert_dynamic_result(:from_local, "helper_value", { helper_value: :from_local })
    assert_dynamic_result(:from_helper, "helper_value", {})
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
    # defined? does not evaluate its operand, so the assignment never runs.
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

    # When `v` is a supplied local it is a single outer variable shared by every
    # block invocation, so all the escaping closures read the same final value.
    assert_equal [3, 3, 3], eval_with_locals(src, { v: 0 })

    # When `v` is omitted it is block-local: each invocation gets a fresh binding
    # and each closure captures its own value. The rewrite strategy always hoists
    # `v` into one shared method-level local, so it wrongly returns [3, 3, 3] here.
    assert_equal [1, 2, 3], eval_with_locals(src)
  end

  def test_block_assignment_stays_block_local_when_outer_assignment_is_later
    src = "1.times { x = 1 }\nx = 5 if false\nx"

    # When `x` is supplied it is an outer local, so `x = 1` inside the block
    # captures it and the trailing `x` reads 1.
    assert_equal 1, eval_with_locals(src, { x: 99 })

    # When `x` is omitted, scoping is decided lexically: at the point the block is
    # parsed `x` is not yet an outer local (its only outer assignment appears
    # later), so `x = 1` is block-local and the trailing `x` reads the method-level
    # `x`, which stays nil because `x = 5 if false` never runs. The rewrite
    # strategy hoists `x` into one shared local, so the block assignment leaks as 1.
    assert_nil eval_with_locals(src)
  end

  def test_pattern_match_pin_uses_dynamic_local
    # `^foo` requires `foo` to already be a known local at parse time. When `foo`
    # is supplied as a dynamic local it should pin to that value, but the rewrite
    # strategy parses the raw source before `foo` exists as a local, so parsing
    # fails with a SyntaxError instead of matching.
    assert_dynamic_result(:matched, "case numeric_value; in ^foo then :matched; else :no; end", { foo: 40 })
  end

  def test_method_body_implicit_rescue
    # The input is a method body, where a bare `rescue` is an implicit
    # begin/rescue. Parsing the source as a standalone program rejects it, so
    # this body cannot be translated at all.
    assert_dynamic_result(:rescued, "raise 'boom'\nrescue\n:rescued")
  end

  def test_method_definitions_do_not_capture_dynamic_locals
    ex = assert_raises(NameError) do
      eval_with_locals("def self.__dynamic_locals_method_probe; foo; end; __dynamic_locals_method_probe", { foo: 123 })
    end

    assert_match(/undefined local variable or method [`']foo['`]/, ex.message)
  end

  def test_binding
    assert_dynamic_result(true, "binding.local_variables.include?(:foo)", { foo: 123 })
    assert_dynamic_result(123, "binding.local_variable_get(:foo)", { foo: 123 })
    assert_dynamic_result(123, "binding.eval('foo')", { foo: 123 })
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
end

class RewriteTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::RewriteTranslator

  def eval_with_keyword_locals(src, locals={})
    translator = Implementation.new(src, lookup_strategy: :keywords)
    method_name = :__dynamic_locals_keyword_strategy_test
    params = translator.keyword_parameters(rest: :__dynamic_locals_unused_keywords)

    singleton_class.class_eval("def #{method_name}(#{params}); #{translator.translate}; end")
    send(method_name, **locals)
  ensure
    singleton_class.remove_method(method_name) if method_name && singleton_class.method_defined?(method_name)
  end

  def test_syntax_errors_are_raised_at_translate_time
    assert_raises(SyntaxError) do
      Implementation.new("def").translate
    end
  end

  def test_custom_locals_hash_name
    dynamic = Implementation.new("foo + bar", locals_hash: :view_locals).translate

    assert_equal 5, eval("view_locals = { foo: 2, bar: 3 }; #{dynamic}")
  end

  def test_keyword_lookup_strategy_parameters
    translator = Implementation.new("foo + bar", lookup_strategy: :keywords)

    assert_equal "bar: (__dynamic_locals_unset_0 = true; nil), foo: (__dynamic_locals_unset_1 = true; nil)", translator.keyword_parameters
    assert_equal "bar: (__dynamic_locals_unset_0 = true; nil), foo: (__dynamic_locals_unset_1 = true; nil), **rest", translator.keyword_parameters(rest: :rest)
  end

  def test_keyword_lookup_strategy_bare_reads
    assert_equal :from_local, eval_with_keyword_locals("helper_value", { helper_value: :from_local })
    assert_equal :from_helper, eval_with_keyword_locals("helper_value")
  end

  def test_keyword_lookup_strategy_or_assignment
    assert_equal :existing, eval_with_keyword_locals("foo ||= missing_value; foo", { foo: :existing })
    assert_equal :from_default_helper, eval_with_keyword_locals("foo ||= default_value; foo")
    assert_equal :from_default_helper, eval_with_keyword_locals("foo ||= default_value; foo", { foo: nil })
    assert_equal :from_default_local, eval_with_keyword_locals("foo ||= default_value; foo", { default_value: :from_default_local })
  end

  def test_keyword_lookup_strategy_defined
    assert_equal "local-variable", eval_with_keyword_locals("defined?(helper_value)", { helper_value: :from_local })
    assert_equal "local-variable", eval_with_keyword_locals("defined?(helper_value)", { helper_value: nil })
    assert_equal "method", eval_with_keyword_locals("defined?(helper_value)")
    assert_nil eval_with_keyword_locals("defined?(missing_value)")
  end

  def test_keyword_lookup_strategy_assigned_local_initialization
    assert_equal 6, eval_with_keyword_locals("foo = foo + numeric_value; foo", { foo: 1, numeric_value: 5 })
    assert_equal :from_default_helper, eval_with_keyword_locals("helper_value ||= default_value; helper_value")
  end

  def test_keyword_lookup_strategy_absorbs_unused_keywords
    assert_equal :from_helper, eval_with_keyword_locals("helper_value", { unused: :ignored })
  end

  def test_keyword_lookup_strategy_keeps_binding_as_method_call
    translator = Implementation.new("binding", lookup_strategy: :keywords)

    assert_equal "", translator.keyword_parameters
    assert_instance_of Binding, eval_with_keyword_locals("binding")
  end
end

class KeywordRewriteTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::RewriteTranslator

  def eval_with_locals(src, locals={})
    translator = Implementation.new(src, lookup_strategy: :keywords)
    method_name = :__dynamic_locals_keyword_common_test
    params = translator.keyword_parameters(rest: :__dynamic_locals_unused_keywords)

    singleton_class.class_eval("def #{method_name}(#{params}); #{translator.translate}; end")
    send(method_name, **locals)
  ensure
    singleton_class.remove_method(method_name) if method_name && singleton_class.method_defined?(method_name)
  end

  def test_binding
    assert_instance_of Binding, eval_with_locals("binding", { foo: 123 })
  end
end
