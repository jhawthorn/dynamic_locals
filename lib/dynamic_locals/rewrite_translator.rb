module DynamicLocals
  module RewriteTranslator
    extend self

    def translate(original_src, locals_hash: :locals)
      root = RubyVM::AbstractSyntaxTree.parse(original_src)
      vcalls = extract_vcalls(root)

      line_offsets = [0]
      idx = 0
      while idx = original_src.index("\n", idx)
        idx += 1
        line_offsets << idx
      end

      vcalls = vcalls.sort_by { |x| range_from(line_offsets, x).end }.reverse

      src = original_src.dup
      vcalls.each do |vcall|
        name = vcall.children[0]
        range = range_from(line_offsets, vcall)
        original = src[range]
        src[range] = "#{locals_hash}.fetch(#{name.inspect}){ #{name}() }"
      end

      src
    end

    private

    def position_from(line_offsets, line, column)
      line_offsets[line-1] + column
    end

    def range_from(line_offsets, node)
      first = position_from(line_offsets, node.first_lineno, node.first_column)
      last  = position_from(line_offsets, node.last_lineno, node.last_column)
      first...last
    end

    def extract_vcalls(node)
      return [] unless RubyVM::AbstractSyntaxTree::Node === node
      vars = node.children.flat_map { |child| extract_vcalls(child)  }
      if node.type == :VCALL
        vars << node
      end
      vars
    end
  end
end
