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

  def test_no_variables
    assert_dynamic_result(2, "1+1")
  end

  def test_variable_access
    assert_dynamic_result(2, "foo", { foo: 2 })
  end
end

class EvalTranslatorTest < Minitest::Test
  include CommonBehaviour
  Implementation = DynamicLocals::EvalTranslator
end
