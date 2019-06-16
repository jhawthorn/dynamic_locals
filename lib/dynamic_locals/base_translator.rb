module DynamicLocals
  class BaseTranslator
    attr_reader :original_src, :locals_hash

    def initialize(src, locals_hash: :locals)
      @original_src = src
      @locals_hash = locals_hash
    end

    def translate
      raise NotImplemented
    end
  end
end
