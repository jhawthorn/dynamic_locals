require "test_helper"

class DynamicLocalsTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::DynamicLocals::VERSION
  end
end

module CommonBehaviour
  def assert_dynamic_result(expected, src, locals={})
    dynamic = self.class::Implementation.translate(src)
    dynamic = "locals = (#{locals.inspect});#{dynamic}"
    actual = eval(dynamic)
    assert_equal expected, actual, "Expected #{actual.inspect} to equal #{expected.inspect}"
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

  def test_method_call_block
    assert_dynamic_result(:hi_from_my_method, "my_method_name {}", { my_method_name: :a_local })
  end
end

class EvalTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::EvalTranslator
end
