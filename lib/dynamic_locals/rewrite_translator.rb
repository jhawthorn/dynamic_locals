require "dynamic_locals/base_translator"

module DynamicLocals
  class RewriteTranslator < BaseTranslator
    def initialize(*args)
      super

      @replacements = []

      root = RubyVM::AbstractSyntaxTree.parse(original_src)
      find_replacements(root)
    end

    def translate
      root = RubyVM::AbstractSyntaxTree.parse(original_src)
      rewrites = @replacements
      rewrites =
        rewrites.sort_by do |range, replacement|
          range.end
        end.reverse

      src = original_src.dup
      rewrites.each do |range, rewrite|
        src[range] = rewrite
      end

      src
    end

    private

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

    def position_from(line, column)
      line_offsets[line-1] + column
    end

    def range_from(node)
      first = position_from(node.first_lineno, node.first_column)
      last  = position_from(node.last_lineno, node.last_column)
      first...last
    end

    def original_src_of(node)
      @original_src[range_from(node)]
    end

    def add_replacement(node, replacement)
      range = range_from(node)
      @replacements << [range, replacement]
    end

    def find_replacements(node)
      return unless RubyVM::AbstractSyntaxTree::Node === node
      if node.type == :VCALL
        rewrites = node.children.each { |child| find_replacements(child)  }

        name = node.children[0]
        replacement = "#{locals_hash}.fetch(#{name.inspect}){ #{name}() }"
        add_replacement node, replacement
      elsif node.type == :DEFINED && node.children[0].type == :VCALL
        name = node.children[0].children[0]
        replacement = "(#{locals_hash}.key?(#{name.inspect}) ? 'local-variable'.freeze : defined?(#{name}))"
        add_replacement node, replacement
      elsif node.type == :OP_ASGN_OR && node.children[0].type == :LVAR
        name = node.children[0].children[0]
        preface = "#{name} = #{locals_hash}[#{name.inspect}]"
        preface = "unless defined?(#{name}) == 'local-variable'.freeze;#{preface};end"
        replacement = "#{preface};#{original_src_of(node)}"
        add_replacement node, replacement
      else
        node.children.each { |child| find_replacements(child)  }
      end
    end
  end
end
