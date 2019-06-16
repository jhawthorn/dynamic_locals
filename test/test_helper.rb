$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "dynamic_locals"

require "minitest/autorun"

class Minitest::Test
  def self.skip(method_name)
    raise "no such test: #{method_name}" unless public_method_defined?(method_name)
    define_method(method_name) { skip }
  end
end
