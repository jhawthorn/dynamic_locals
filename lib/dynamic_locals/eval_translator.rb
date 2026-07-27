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
      %{eval(#{locals_hash}.keys.map { |k| "\#{k} = #{locals_hash}[\#{k.inspect}];" }.join + #{body.inspect})}
    end
  end
end
