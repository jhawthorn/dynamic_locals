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
      %{eval(#{locals_hash}.map { |k, v| "\#{k} = \#{v.inspect};" }.join + #{original_src.inspect})}
    end
  end
end
