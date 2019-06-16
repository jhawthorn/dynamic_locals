module DynamicLocals
  module RewriteTranslator
    extend self

    def translate(original_src)
      root = RubyVM::AbstractSyntaxTree.parse(original_src)
      vcalls = extract_vcalls(root)
      vcalls = vcalls.sort_by(&:last_column).reverse

      src = original_src.dup
      vcalls.each do |vcall|
        name = vcall.children[0]
        range = (vcall.first_column)...(vcall.last_column)
        original = src[range]
        src[(vcall.first_column)...(vcall.last_column)] = "locals.fetch(#{name.inspect}){ #{name}() }"
      end

      src
    end

    private

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
