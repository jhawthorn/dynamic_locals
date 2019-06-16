require "test_helper"

class DynamicLocalsTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::DynamicLocals::VERSION
  end
end

module CommonBehaviour
  def assert_dynamic_result(expected, src, locals={})
    dynamic = self.class::Implementation.new(src).translate
    dynamic = "locals = (#{locals.inspect});#{dynamic}"
    actual = eval(dynamic)
    assert expected == actual, "Expected #{actual.inspect} to equal #{expected.inspect}"
  end

  def my_method_name
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

  def test_multiline_rewrites
    src = <<~RUBY
      three = one + two
      one + three + eight
    RUBY

    assert_dynamic_result(12, src, { one: 1, two: 2, eight: 8 })
  end

  def test_defined
    assert_dynamic_result(nil, "defined?(foo)", { })
    assert_dynamic_result("local-variable", "defined?(foo)", { foo: 123 })

    assert_dynamic_result("method", "defined?(my_method_name)", { })
    assert_dynamic_result("local-variable", "defined?(my_method_name)", { my_method_name: 123 })
  end
end

class EvalTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::EvalTranslator
end

class RewriteTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::RewriteTranslator
end
