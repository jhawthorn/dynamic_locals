require "dynamic_locals/base_translator"
require "dynamic_locals/ast_rewriter"

module DynamicLocals
  class RewriteTranslator < BaseTranslator
    def initialize(*args, **kwargs)
      super(*args, **kwargs)

      @rewriter = ASTRewriter.new(original_src)

      root = @rewriter.ast
      @assigned_locals = root.locals
      @dynamic_locals = @assigned_locals.dup
      @keyword_unset_flags = {}
      collect_dynamic_locals(root)
      dynamic_locals.each { |local| keyword_unset_flag(local) } if lookup_strategy == :keywords
      find_replacements(root)
    end

    def dynamic_locals
      @dynamic_locals.sort.uniq
    end

    def keyword_parameters(rest: nil)
      params = dynamic_locals.map do |local|
        "#{local}: (#{keyword_unset_flag(local)} = true; nil)"
      end
      params << "**#{rest}" if rest
      params.join(", ")
    end

    def translate
      src = @rewriter.modified_src

      initialize = initialize_assigned_locals

      "#{initialize}#{src}"
    end

    private

    def collect_dynamic_locals(node)
      return unless Prism::Node === node

      if defined_variable_call?(node)
        @dynamic_locals << node.value.name
      elsif binding_call?(node)
        # Keep Kernel#binding as a method call; it is not a dynamic local.
      elsif variable_call?(node)
        @dynamic_locals << node.name
      else
        child_nodes_for_method_body(node).each { |child| collect_dynamic_locals(child) }
      end
    end

    def find_replacements(node)
      return unless Prism::Node === node

      if defined_variable_call?(node)
        name = node.value.name
        replacement = defined_lookup_src(name)
        @rewriter.replace node, replacement
      elsif binding_call?(node) && lookup_strategy == :hash
        # Assumes binding isn't a local and isn't overridden
        replacement = "(_binding = binding; #{locals_hash}.each { |k,v| _binding.local_variable_set(k, v) }; _binding)"
        @rewriter.replace node, replacement
      elsif binding_call?(node)
        # The keyword strategy already has real local variables for known locals,
        # so leave Kernel#binding as a normal method call.
      elsif variable_call?(node)
        name = node.name
        fallback = @assigned_locals.include?(name) ? "#{name}()" : name.to_s
        replacement = local_lookup_src(name, fallback)
        @rewriter.replace node, replacement
      elsif Prism::DefNode === node
        find_replacements(node.receiver)
      else
        child_nodes_for_method_body(node).each { |child| find_replacements(child) }
      end
    end

    def initialize_assigned_locals
      @assigned_locals.sort.uniq.map do |local|
        case lookup_strategy
        when :hash
          "#{local} = #{locals_hash}[#{local.inspect}];"
        when :keywords
          ""
        else
          raise ArgumentError, "unknown lookup strategy: #{lookup_strategy.inspect}"
        end
      end.join
    end

    def local_lookup_src(name, fallback)
      case lookup_strategy
      when :hash
        "#{locals_hash}.fetch(#{name.inspect}){ #{fallback} }"
      when :keywords
        "(#{keyword_unset_flag(name)} ? #{name}() : #{name})"
      else
        raise ArgumentError, "unknown lookup strategy: #{lookup_strategy.inspect}"
      end
    end

    def defined_lookup_src(name)
      case lookup_strategy
      when :hash
        "(#{locals_hash}.key?(#{name.inspect}) ? 'local-variable'.freeze : defined?(#{name}()))"
      when :keywords
        "(#{keyword_unset_flag(name)} ? defined?(#{name}()) : 'local-variable'.freeze)"
      else
        raise ArgumentError, "unknown lookup strategy: #{lookup_strategy.inspect}"
      end
    end

    def keyword_unset_flag(name)
      @keyword_unset_flags[name] ||= begin
        index = @keyword_unset_flags.length
        temp = :"__dynamic_locals_unset_#{index}"
        reserved = dynamic_locals + @keyword_unset_flags.values
        while reserved.include?(temp)
          index += 1
          temp = :"__dynamic_locals_unset_#{index}"
        end
        temp
      end
    end

    def child_nodes_for_method_body(node)
      return [node.receiver] if Prism::DefNode === node

      node.child_nodes
    end

    def variable_call?(node)
      Prism::CallNode === node && node.variable_call?
    end

    def binding_call?(node)
      variable_call?(node) && node.name == :binding
    end

    def defined_variable_call?(node)
      Prism::DefinedNode === node && variable_call?(node.value)
    end
  end
end
