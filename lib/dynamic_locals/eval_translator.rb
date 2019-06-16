module DynamicLocals
  # This is (probably) the simplest possible implementation of the behaviour we
  # want. It builds a new string of Ruby code with assignments to the locals
  # each time it is called and evals that string.
  #
  # This is not intended to be used in production code, but for debugging and
  # as a reference implementation.
  module EvalTranslator
    extend self

    def translate(src)
      %{eval(locals.map { |k, v| "\#{k} = \#{v.inspect};" }.join + #{src.inspect})}
    end
  end
end
