module DynamicLocals
  class ASTRewriter
    def initialize(source)
      @original_src = source.dup.freeze
      @ast = RubyVM::AbstractSyntaxTree.parse(original_src)
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
      raise TypeError unless RubyVM::AbstractSyntaxTree::Node === node

      start = range_from(node).begin
      range = start...start
      @replacements << Replacement.new(range, src)
    end

    def replace(node, src)
      raise TypeError unless RubyVM::AbstractSyntaxTree::Node === node

      range = range_from(node)
      @replacements << Replacement.new(range, src)
    end

    private

    def position_from(line, column)
      line_offsets[line-1] + column
    end

    def range_from(node)
      first = position_from(node.first_lineno, node.first_column)
      last  = position_from(node.last_lineno, node.last_column)
      first...last
    end

    def line_offsets
      @line_offsets ||=
        begin
          line_offsets = [0]
          idx = 0
          while idx = original_src.index("\n", idx)
            idx += 1
            line_offsets << idx
          end
          line_offsets
        end
    end
  end
end
