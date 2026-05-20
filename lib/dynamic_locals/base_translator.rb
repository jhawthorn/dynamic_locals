module DynamicLocals
  class BaseTranslator
    attr_reader :original_src, :locals_hash, :lookup_strategy

    def initialize(src, locals_hash: :locals, lookup_strategy: :hash)
      @original_src = src
      @locals_hash = locals_hash
      @lookup_strategy = lookup_strategy
    end

    def translate
      raise NotImplementedError
    end
  end
end
