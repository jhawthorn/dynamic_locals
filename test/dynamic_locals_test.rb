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

  def my_method_name(&block)
    :hi_from_my_method
  end

  def test_no_variables
    assert_dynamic_result(2, "1+1")
  end

  def test_variable_access
    assert_dynamic_result(2, "foo", { foo: 2 })
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

  def test_and_assignment
    assert_dynamic_result(:replacement, "foo &&= bar; foo", { foo: true, bar: :replacement })
    assert_dynamic_result(false, "foo &&= bar; foo", { foo: false, bar: :replacement })
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

  def test_dynamic_locals_inside_blocks
    assert_dynamic_result([123], "[1].map { foo }", { foo: 123 })
    assert_dynamic_result([3], "[1].map { |one| one + two }", { two: 2 })
  end

  def test_dynamic_locals_inside_lambdas
    assert_dynamic_result(123, "-> { foo }.call", { foo: 123 })
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
    ex = assert_raises do
      eval_with_locals("undefined_method_or_local")
    end

    assert_equal NameError, ex.class
    assert_match(/undefined local variable or method [`']undefined_method_or_local['`]/, ex.message)
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

  def test_syntax_errors_are_raised_at_translate_time
    assert_raises(SyntaxError) do
      Implementation.new("def").translate
    end
  end

  def test_custom_locals_hash_name
    dynamic = Implementation.new("foo + bar", locals_hash: :view_locals).translate

    assert_equal 5, eval("view_locals = { foo: 2, bar: 3 }; #{dynamic}")
  end
end
