require "dynamic_locals/base_translator"
require "dynamic_locals/ast_rewriter"

module DynamicLocals
  class RewriteTranslator < BaseTranslator
    def initialize(*args, **kwargs)
      super(*args, **kwargs)

      @rewriter = ASTRewriter.new(original_src)

      root = @rewriter.ast
      # Names assigned anywhere in this method body. Earlier occurrences of
      # these names can still be CallNodes, e.g. `foo; foo = 123`.
      @local_table = root.locals
      @dynamic_locals = @local_table.dup
      @keyword_unset_flags = {}
      collect_dynamic_locals(root)
      dynamic_locals.each { |local| keyword_unset_flag(local) } if lookup_strategy == :keywords
      insert_nested_scope_resets(root)
      find_replacements(root)
    end

    def dynamic_locals
      @dynamic_locals.sort.uniq
    end

    def keyword_parameters(rest: nil)
      return "locals = {}" unless lookup_strategy == :keywords
      params = dynamic_locals.map do |local|
        "#{local}: (#{keyword_unset_flag(local)} = true; nil)"
      end
      params << "**#{rest}" if rest
      params.join(", ")
    end

    def translate
      src = @rewriter.modified_src

      initialize = initialize_local_table

      "#{initialize}#{src}"
    end

    def to_s(name="dynamic")
      "def #{name}(#{keyword_parameters})\n#{translate}\nend"
    end

    private

    def collect_dynamic_locals(node)
      return unless Prism::Node === node

      if nested_scope?(node)
        nested_local_table(node).each do |local|
          @local_table << local
          @dynamic_locals << local
        end

        child_nodes_for_method_body(node).each { |child| collect_dynamic_locals(child) }
      elsif defined_variable_call?(node)
        @dynamic_locals << node.value.name
      elsif binding_call?(node)
        # Keep Kernel#binding as a method call; it is not a dynamic local.
      elsif variable_call?(node)
        @dynamic_locals << node.name
      else
        child_nodes_for_method_body(node).each { |child| collect_dynamic_locals(child) }
      end
    end

    def insert_nested_scope_resets(node)
      return unless Prism::Node === node

      if nested_scope?(node)
        locals = nested_local_table(node) & dynamic_locals
        if locals.any? && (first_statement = first_statement(node))
          @rewriter.insert_before(first_statement, nested_scope_reset_src(locals))
        end
      end

      child_nodes_for_method_body(node).each { |child| insert_nested_scope_resets(child) }
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
        fallback = @local_table.include?(name) ? "#{name}()" : name.to_s
        replacement = local_lookup_src(name, fallback)
        @rewriter.replace node, replacement
      elsif Prism::DefNode === node
        find_replacements(node.receiver)
      else
        child_nodes_for_method_body(node).each { |child| find_replacements(child) }
      end
    end

    def initialize_local_table
      @local_table.sort.uniq.map do |local|
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
        if @local_table.include?(name)
          "(#{locals_hash}.key?(#{name.inspect}) ? #{name} : #{fallback})"
        else
          "#{locals_hash}.fetch(#{name.inspect}){ #{fallback} }"
        end
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

    def nested_scope_reset_src(locals)
      locals.sort.uniq.map do |local|
        case lookup_strategy
        when :hash
          "#{local} = nil unless #{locals_hash}.key?(#{local.inspect});"
        when :keywords
          "#{local} = nil if #{keyword_unset_flag(local)};"
        else
          raise ArgumentError, "unknown lookup strategy: #{lookup_strategy.inspect}"
        end
      end.join
    end

    def nested_local_table(node)
      node.locals - parameter_names(node.parameters)
    end

    def parameter_names(node, names = [])
      return names unless Prism::Node === node

      if parameter_node?(node) && node.respond_to?(:name) && node.name
        names << node.name
      elsif Prism::BlockLocalVariableNode === node
        names << node.name
      end

      node.child_nodes.each { |child| parameter_names(child, names) }
      names
    end

    def parameter_node?(node)
      node.class.name.start_with?("Prism::") && node.class.name.end_with?("ParameterNode")
    end

    def first_statement(node)
      statements_node(node.body)&.body&.first
    end

    # A block/lambda body is normally a StatementsNode, but becomes a BeginNode
    # when the scope has a rescue/else/ensure clause (e.g. `foo do ... rescue ... end`).
    def statements_node(body)
      case body
      when Prism::StatementsNode then body
      when Prism::BeginNode then body.statements
      end
    end

    def nested_scope?(node)
      Prism::BlockNode === node || Prism::LambdaNode === node
    end

    def child_nodes_for_method_body(node)
      return [node.receiver] if Prism::DefNode === node

      node.child_nodes
    end

    def variable_call?(node)
      Prism::CallNode === node && node.variable_call? && !known_locals.include?(node.name)
    end

    def binding_call?(node)
      variable_call?(node) && node.name == :binding
    end

    def defined_variable_call?(node)
      Prism::DefinedNode === node && variable_call?(node.value)
    end
  end
end
