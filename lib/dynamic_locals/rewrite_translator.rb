require "dynamic_locals/base_translator"
require "dynamic_locals/ast_rewriter"

module DynamicLocals
  class RewriteTranslator < BaseTranslator
    def initialize(*args, **kwargs)
      super(*args, **kwargs)

      @rewriter = ASTRewriter.new(original_src)

      root = @rewriter.ast
      @assigned_locals = root.locals
      find_replacements(root)
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
      return unless Prism::Node === node

      if defined_variable_call?(node)
        name = node.value.name
        replacement = "(#{locals_hash}.key?(#{name.inspect}) ? 'local-variable'.freeze : defined?(#{name}))"
        @rewriter.replace node, replacement
      elsif variable_call?(node) && node.name == :binding
        # Assumes binding isn't a local and isn't overridden
        replacement = "(_binding = binding; #{locals_hash}.each { |k,v| _binding.local_variable_set(k, v) }; _binding)"
        @rewriter.replace node, replacement
      elsif variable_call?(node)
        name = node.name
        fallback = @assigned_locals.include?(name) ? "#{name}()" : name.to_s
        replacement = "#{locals_hash}.fetch(#{name.inspect}){ #{fallback} }"
        @rewriter.replace node, replacement
      elsif Prism::DefNode === node
        find_replacements(node.receiver)
      else
        node.child_nodes.each { |child| find_replacements(child) }
      end
    end

    def variable_call?(node)
      Prism::CallNode === node && node.variable_call?
    end

    def defined_variable_call?(node)
      Prism::DefinedNode === node && variable_call?(node.value)
    end
  end
end
