module DynamicLocals
  class BaseTranslator
    attr_reader :original_src, :locals_hash, :lookup_strategy, :known_locals

    def initialize(src, locals_hash: :locals, lookup_strategy: :hash, known_locals: [])
      @original_src = src
      @locals_hash = locals_hash
      @lookup_strategy = lookup_strategy
      @known_locals = Array(known_locals).map(&:to_sym)
    end

    def translate
      raise NotImplementedError
    end

    # The parameter list that pairs with the translated body. The default shape
    # takes the locals as a single hash argument; strategies that use real
    # parameters (see RewriteTranslator's keyword strategy) override this.
    def parameters
      "#{locals_hash} = {}"
    end

    # Wrap the translated body in a method definition.
    def to_s(name = "__dynamic_locals__")
      "def #{name}(#{parameters})\n#{translate}\nend"
    end
  end
end
