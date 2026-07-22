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
      @local_table = @rewriter.locals
      @dynamic_locals = @local_table.dup
      @keyword_unset_flags = {}
      @shadowed_locals = []
      @shadow_names = {}
      @generated_names = []
      collect_dynamic_locals(root)
      dynamic_locals.each { |local| keyword_unset_flag(local) } if lookup_strategy == :keywords
      find_replacements(root, [:root])
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

    def to_s(name = "__dynamic_locals__")
      # In the keyword strategy the locals are real parameters; absorb any
      # unsupplied-but-passed keys so callers can splat an arbitrary hash.
      params = keyword_parameters(rest: :__dynamic_locals_unused_keywords)
      "def #{name}(#{params})\n#{translate}\nend"
    end

    private

    def collect_dynamic_locals(node)
      return unless Prism::Node === node

      if nested_scope?(node)
        nested_local_table(node).each do |local|
          @local_table << local
          @dynamic_locals << local
          # Pre-declaring a dynamic local as a method-level variable changes
          # the scoping of assignments inside blocks: plain Ruby would have
          # created a fresh block-local per invocation. These names get a
          # "shadow" variable whose assignments are co-located with the
          # original ones, so its scope structure matches plain Ruby's.
          @shadowed_locals << local unless known_locals.include?(local)
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

    def find_replacements(node, scopes)
      return unless Prism::Node === node

      if nested_scope?(node)
        inner = scopes + [node]
        child_nodes_for_method_body(node).each { |child| find_replacements(child, inner) }
      elsif defined_variable_call?(node)
        name = node.value.name
        replacement = defined_lookup_src(name)
        @rewriter.replace node, replacement
      elsif Prism::DefinedNode === node && Prism::LocalVariableReadNode === node.value
        # `defined?` of a real local is 'local-variable' whether the name was
        # supplied or shadow-assigned, so leave it alone. Rewriting the read
        # into a guarded expression would change the answer to 'expression'.
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
      elsif Prism::LocalVariableReadNode === node
        if shadow_binding?(node.name, node.depth, scopes)
          @rewriter.replace node, shadow_read_src(node.name)
        end
      elsif Prism::LocalVariableWriteNode === node
        if shadow_binding?(node.name, node.depth, scopes)
          @rewriter.insert_before(node, "#{shadow_name(node.name)} = ")
        end
        find_replacements(node.value, scopes)
      elsif local_operator_write?(node)
        expand_operator_write(node, scopes) if shadow_binding?(node.name, node.depth, scopes)
        find_replacements(node.value, scopes)
      elsif Prism::MultiWriteNode === node
        shadow_multi_write(node, scopes)
        child_nodes_for_method_body(node).each { |child| find_replacements(child, scopes) }
      elsif Prism::RescueNode === node
        shadow_rescue_reference(node, scopes)
        child_nodes_for_method_body(node).each { |child| find_replacements(child, scopes) }
      elsif Prism::ForNode === node
        shadow_for_index(node, scopes)
        child_nodes_for_method_body(node).each { |child| find_replacements(child, scopes) }
      else
        child_nodes_for_method_body(node).each { |child| find_replacements(child, scopes) }
      end
    end

    # True when a read/write of +name+ resolves to a binding that was declared
    # by assignment rather than by a parameter or explicit block-local -- those
    # are the bindings whose scoping our pre-declaration changed, so they must
    # go through the shadow variable. Parameter bindings shadow the dynamic
    # local in plain Ruby too and stay untouched.
    def shadow_binding?(name, depth, scopes)
      return false unless @shadowed_locals.include?(name)
      scope = scopes[scopes.length - 1 - depth]
      return true if scope == :root
      !scope_parameter_names(scope).include?(name)
    end

    def scope_parameter_names(scope)
      @scope_parameter_names ||= {}
      @scope_parameter_names[scope] ||= parameter_names(scope.parameters)
    end

    # `x = v` => `x_local = x = v`
    # The kwarg keeps its real name (callers supply it), and the shadow gets a
    # fresh block-local binding exactly where plain `x` would have.
    def shadow_name(name)
      @shadow_names[name] ||= generate_hygienic_name("#{name}_local")
    end

    def discard_name
      @discard_name ||= generate_hygienic_name("__dynamic_locals_discard")
    end

    def generate_hygienic_name(base)
      candidate = base.to_sym
      index = 0
      while reserved_name?(candidate)
        index += 1
        candidate = :"#{base}#{index}"
      end
      @generated_names << candidate
      candidate
    end

    def reserved_name?(name)
      @generated_names.include?(name) ||
        @keyword_unset_flags.value?(name) ||
        @dynamic_locals.include?(name) ||
        original_src.match?(/\b#{Regexp.escape(name.to_s)}\b/)
    end

    # Selects the plain variable when the local was supplied, the shadow
    # otherwise. Needed even for method-level bindings: when the local is
    # unset, the double-write leaves garbage in the kwarg.
    def shadow_read_src(name)
      case lookup_strategy
      when :hash
        "(#{locals_hash}.key?(#{name.inspect}) ? #{name} : #{shadow_name(name)})"
      when :keywords
        "(#{keyword_unset_flag(name)} ? #{shadow_name(name)} : #{name})"
      else
        raise ArgumentError, "unknown lookup strategy: #{lookup_strategy.inspect}"
      end
    end

    # `x op= v` => `x_local = x = <guarded read> op (v)`
    # The parens around the value preserve associativity (`x -= a - b`).
    def expand_operator_write(node, scopes)
      name = node.name
      op =
        case node
        when Prism::LocalVariableOrWriteNode then "||"
        when Prism::LocalVariableAndWriteNode then "&&"
        else node.binary_operator.to_s
        end
      prefix = "#{shadow_name(name)} = #{name} = #{shadow_read_src(name)} #{op} ("
      @rewriter.replace_offsets(node.location.start_offset, node.value.location.start_offset, prefix)
      @rewriter.insert_after(node.value, ")")
    end

    # `a, b = v` => `a_local, b_local = (a, b = v)`
    # A masgn evaluates to its right-hand side, so a structurally identical
    # outer masgn assigns the same values to the shadows. Targets that don't
    # need a shadow become a discard variable (duplicates are legal).
    def shadow_multi_write(node, scopes)
      copied, any = copy_masgn_targets(node, scopes)
      return unless any
      @rewriter.insert_before(node, "#{copied} = (")
      @rewriter.insert_after(node, ")")
    end

    def copy_masgn_targets(node, scopes)
      any = false
      items = []
      node.lefts.each do |target|
        src, hit = copy_masgn_target(target, scopes)
        any ||= hit
        items << src
      end
      case node.rest
      when Prism::SplatNode
        if (expression = node.rest.expression)
          src, hit = copy_masgn_target(expression, scopes)
          any ||= hit
          items << "*#{src}"
        else
          items << "*"
        end
      when Prism::ImplicitRestNode
        items << ""
      end
      node.rights.each do |target|
        src, hit = copy_masgn_target(target, scopes)
        any ||= hit
        items << src
      end
      [items.join(", "), any]
    end

    def copy_masgn_target(node, scopes)
      case node
      when Prism::LocalVariableTargetNode
        if shadow_binding?(node.name, node.depth, scopes)
          [shadow_name(node.name).to_s, true]
        else
          [discard_name.to_s, false]
        end
      when Prism::MultiTargetNode
        src, any = copy_masgn_targets(node, scopes)
        ["(#{src})", any]
      else
        # Attribute/index/constant/etc. targets: assign to a discard variable
        # instead so the side effect isn't repeated.
        [discard_name.to_s, false]
      end
    end

    # `rescue => e` has no expression form to wrap, so sync the shadow as the
    # first statement of the rescue body.
    def shadow_rescue_reference(node, scopes)
      reference = node.reference
      return unless Prism::LocalVariableTargetNode === reference
      return unless shadow_binding?(reference.name, reference.depth, scopes)

      sync = "#{shadow_name(reference.name)} = #{reference.name}"
      if (first = node.statements&.body&.first)
        @rewriter.insert_before(first, "#{sync}; ")
      elsif node.respond_to?(:then_keyword_loc) && node.then_keyword_loc
        @rewriter.insert_at(node.then_keyword_loc.end_offset, " #{sync};")
      else
        @rewriter.insert_after(reference, "; #{sync}")
      end
    end

    # `for x in list` assigns its index in the enclosing scope; sync the shadow
    # at the top of the loop body.
    def shadow_for_index(node, scopes)
      names = []
      each_local_target(node.index) do |target|
        names << target.name if shadow_binding?(target.name, target.depth, scopes)
      end
      return if names.empty?

      sync = names.map { |name| "#{shadow_name(name)} = #{name}" }.join("; ")
      if (first = node.statements&.body&.first)
        @rewriter.insert_before(first, "#{sync}; ")
      elsif node.do_keyword_loc
        @rewriter.insert_at(node.do_keyword_loc.end_offset, " #{sync};")
      else
        @rewriter.insert_at(node.collection.location.end_offset, " do #{sync}")
      end
    end

    def each_local_target(node, &block)
      return unless Prism::Node === node

      if Prism::LocalVariableTargetNode === node
        yield node
      else
        node.child_nodes.each { |child| each_local_target(child, &block) }
      end
    end

    def local_operator_write?(node)
      Prism::LocalVariableOperatorWriteNode === node ||
        Prism::LocalVariableOrWriteNode === node ||
        Prism::LocalVariableAndWriteNode === node
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
        reserved = dynamic_locals + @keyword_unset_flags.values + @generated_names
        while reserved.include?(temp)
          index += 1
          temp = :"__dynamic_locals_unset_#{index}"
        end
        temp
      end
    end

    def nested_local_table(node)
      node.locals - parameter_names(node.parameters)
    end

    def parameter_names(node, names = [])
      return names unless Prism::Node === node

      if Prism::NumberedParametersNode === node
        node.maximum.times { |i| names << :"_#{i + 1}" }
      elsif parameter_node?(node) && node.respond_to?(:name) && node.name
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

    def nested_scope?(node)
      Prism::BlockNode === node || Prism::LambdaNode === node
    end

    # Scopes that don't share our local table: recurse only into the parts
    # still evaluated in the enclosing scope.
    def child_nodes_for_method_body(node)
      case node
      when Prism::DefNode
        [node.receiver]
      when Prism::ClassNode
        [node.superclass]
      when Prism::ModuleNode
        []
      when Prism::SingletonClassNode
        [node.expression]
      else
        node.child_nodes
      end
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
