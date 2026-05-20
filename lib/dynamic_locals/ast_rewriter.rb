require "prism"

module DynamicLocals
  class ASTRewriter
    def initialize(source)
      @original_src = source.dup.freeze
      result = Prism.parse(original_src)
      raise SyntaxError, result.errors.map(&:message).join("\n") unless result.success?

      @ast = result.value
      @replacements = []
    end

    Replacement = Struct.new(:range, :src)

    attr_reader :ast, :original_src

    def modified_src
      rewrites = @replacements
      rewrites =
        rewrites.sort_by do |replacement|
          replacement.range.end
        end.reverse

      src = original_src.b
      rewrites.each do |replacement|
        src[replacement.range] = replacement.src.b
      end
      src.force_encoding(original_src.encoding)
    end
    alias_method :src, :modified_src

    def insert_before(node, src)
      raise TypeError unless Prism::Node === node

      start = range_from(node).begin
      range = start...start
      @replacements << Replacement.new(range, src)
    end

    def replace(node, src)
      raise TypeError unless Prism::Node === node

      range = range_from(node)
      @replacements << Replacement.new(range, src)
    end

    private

    def range_from(node)
      node.location.start_offset...node.location.end_offset
    end
  end
end
