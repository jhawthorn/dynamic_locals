require "dynamic_locals/base_translator"
require "dynamic_locals/ast_rewriter"

module DynamicLocals
  class RewriteTranslator < BaseTranslator
    def initialize(*args)
      super

      @assigned_locals = []

      verbose_was = $VERBOSE
      $VERBOSE = nil
      @rewriter = ASTRewriter.new(original_src)

      root = @rewriter.ast
      find_replacements(root)
      $VERBOSE = verbose_was
    end

    def translate
      src = @rewriter.modified_src

      initialize = @assigned_locals.sort.uniq.map do |local|
        "#{local} = #{locals_hash}[#{local.inspect}];"
      end.join

      "#{initialize}#{src}"
    end

    private

    def find_replacements(node)
      return unless RubyVM::AbstractSyntaxTree::Node === node
      if node.type == :VCALL && node.children == [:binding]
        # Assumes binding isn't a local and isn't overridden
        replacement = "(_binding = binding; #{locals_hash}.each { |k,v| _binding.local_variable_set(k, v) }; _binding)"
        @rewriter.replace node, replacement
      elsif node.type == :VCALL
        node.children.each { |child| find_replacements(child)  }

        name = node.children[0]
        replacement = "#{locals_hash}.fetch(#{name.inspect}){ #{name}() }"
        @rewriter.replace node, replacement
      elsif node.type == :DEFINED && node.children[0].type == :VCALL
        name = node.children[0].children[0]
        replacement = "(#{locals_hash}.key?(#{name.inspect}) ? 'local-variable'.freeze : defined?(#{name}))"
        @rewriter.replace node, replacement
      elsif node.type == :OP_ASGN_OR && node.children[0].type == :LVAR
        node.children.each { |child| find_replacements(child)  }

        name = node.children[0].children[0]
        @assigned_locals << name
      elsif node.type == :LASGN
        node.children.each { |child| find_replacements(child)  }

        name = node.children[0]
        @assigned_locals << name
      else
        node.children.each { |child| find_replacements(child)  }
      end
    end
  end
end
