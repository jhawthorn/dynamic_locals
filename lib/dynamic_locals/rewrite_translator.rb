require "dynamic_locals/base_translator"
require "dynamic_locals/ast_rewriter"

module DynamicLocals
  class RewriteTranslator < BaseTranslator
    def initialize(...)
      super

      unless [:hash, :keywords].include?(lookup_strategy)
        raise ArgumentError, "unknown lookup strategy: #{lookup_strategy.inspect}"
      end

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
      @scope_parameter_names = {}
      collect_dynamic_locals(root)
      # Known locals are real variables that already exist (e.g. method
      # parameters); they are never looked up dynamically, made into kwargs,
      # or initialized from the locals hash.
      @dynamic_locals = @dynamic_locals.sort.uniq - known_locals
      dynamic_locals.each { |local| keyword_unset_flag(local) } if keywords?
      find_replacements(root, [:root])
    end

    attr_reader :dynamic_locals

    def keyword_parameters(rest: nil)
      return "#{locals_hash} = {}" unless keywords?
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

    # In the keyword strategy the locals are real parameters; absorb any
    # unsupplied-but-passed keys so callers can splat an arbitrary hash.
    def parameters
      keyword_parameters(rest: :__dynamic_locals_unused_keywords)
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
      elsif variable_call?(node)
        @dynamic_locals << node.name
      else
        child_nodes_for_method_body(node).each { |child| collect_dynamic_locals(child) }
      end
    end

    # Leaf branches replace a node (or deliberately leave it alone) and return;
    # write branches recurse only into their value; everything else falls
    # through to the generic recursion at the bottom.
    def find_replacements(node, scopes)
      return unless Prism::Node === node

      if nested_scope?(node)
        scopes += [node]
      elsif defined_variable_call?(node)
        # A `defined?` spanning newlines must not pull later lines up;
        # re-emit its newlines inside the parenthesized replacement.
        newlines = "\n" * node.slice.count("\n")
        @rewriter.replace node, "(#{defined_lookup_src(node.value.name)}#{newlines})"
        return
      elsif Prism::DefinedNode === node && Prism::LocalVariableReadNode === node.value
        # `defined?` of a real local is 'local-variable' whether the name was
        # supplied or shadow-assigned, so leave it alone. Rewriting the read
        # into a guarded expression would change the answer to 'expression'.
        return
      elsif variable_call?(node)
        name = node.name
        fallback = @local_table.include?(name) ? "#{name}()" : name.to_s
        @rewriter.replace node, local_lookup_src(name, fallback)
        return
      elsif Prism::LocalVariableReadNode === node
        if shadow_binding?(node.name, node.depth, scopes)
          @rewriter.replace node, shadow_read_src(node.name)
        end
        return
      elsif Prism::LocalVariableWriteNode === node
        if shadow_binding?(node.name, node.depth, scopes)
          @rewriter.insert_before(node, "#{shadow_name(node.name)} = ")
        end
        return find_replacements(node.value, scopes)
      elsif local_operator_write?(node)
        expand_operator_write(node, scopes) if shadow_binding?(node.name, node.depth, scopes)
        return find_replacements(node.value, scopes)
      elsif Prism::MatchWriteNode === node
        shadow_match_write(node, scopes)
        return find_replacements(node.call, scopes)
      elsif Prism::MultiWriteNode === node
        shadow_multi_write(node, scopes)
      elsif Prism::RescueNode === node
        shadow_rescue_reference(node, scopes)
      elsif Prism::ForNode === node
        shadow_for_index(node, scopes)
      elsif Prism::MatchRequiredNode === node
        shadow_required_pattern(node, scopes)
      elsif Prism::MatchPredicateNode === node
        shadow_predicate_pattern(node, scopes)
      elsif Prism::InNode === node
        # This branch owns its recursion: guard syncs must be registered
        # around the predicate's own rewrites (see shadow_in_clause).
        return shadow_in_clause(node, scopes) do
          child_nodes_for_method_body(node).each { |child| find_replacements(child, scopes) }
        end
      end

      child_nodes_for_method_body(node).each { |child| find_replacements(child, scopes) }
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
      @scope_parameter_names[scope] ||= parameter_names(scope.parameters)
    end

    # `x = v` => `__dynamic_locals_shadow_x = x = v`
    # The kwarg keeps its real name (callers supply it), and the shadow gets a
    # fresh block-local binding exactly where plain `x` would have. The leading
    # underscore exempts write-only shadows from unused-variable warnings.
    def shadow_name(name)
      @shadow_names[name] ||= generate_hygienic_name("__dynamic_locals_shadow_#{name}")
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
      # The regex alone can't cover dynamic locals: \b fails around non-word
      # names like emoji identifiers.
      known_locals.include?(name) ||
        @generated_names.include?(name) ||
        @dynamic_locals.include?(name) ||
        original_src.match?(/\b#{Regexp.escape(name.to_s)}\b/)
    end

    # Selects the plain variable when the local was supplied, the shadow
    # otherwise. Needed even for method-level bindings: when the local is
    # unset, the double-write leaves garbage in the kwarg.
    def shadow_read_src(name)
      if keywords?
        "(#{keyword_unset_flag(name)} ? #{shadow_name(name)} : #{name})"
      else
        "(#{locals_hash}.key?(#{name.inspect}) ? #{name} : #{shadow_name(name)})"
      end
    end

    # `x op= v` => `__dynamic_locals_shadow_x = x = <guarded read> op (v)`
    # The parens around the value preserve associativity (`x -= a - b`); any
    # newlines between the operator and its value re-emit after the opening
    # paren so the value keeps its line.
    def expand_operator_write(node, scopes)
      name = node.name
      op =
        case node
        when Prism::LocalVariableOrWriteNode then "||"
        when Prism::LocalVariableAndWriteNode then "&&"
        else node.binary_operator.to_s
        end
      value_offset = node.value.location.start_offset
      newlines = "\n" * node.slice.byteslice(0, value_offset - node.location.start_offset).count("\n")
      prefix = "#{shadow_name(name)} = #{name} = #{shadow_read_src(name)} #{op} (#{newlines}"
      @rewriter.replace_offsets(node.location.start_offset, value_offset, prefix)
      @rewriter.insert_after(node.value, ")")
    end

    # `a, b = v` =>
    # `__dynamic_locals_shadow_a, __dynamic_locals_shadow_b = (a, b = v)`
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

    # `/(?<word>...)/ =~ str` assigns its named captures as locals. It's an
    # expression (often a condition), so sync the shadows inside a wrapper that
    # preserves the match result:
    # `(tmp = (re =~ str); __dynamic_locals_shadow_word = word; tmp)`
    def shadow_match_write(node, scopes)
      names = node.targets.filter_map do |target|
        next unless Prism::LocalVariableTargetNode === target
        target.name if shadow_binding?(target.name, target.depth, scopes)
      end
      return if names.empty?

      temp = match_temp_name
      syncs = names.map { |name| "#{shadow_name(name)} = #{name}" }.join("; ")
      @rewriter.insert_before(node, "(#{temp} = (")
      @rewriter.insert_after(node, "); #{syncs}; #{temp})")
    end

    def match_temp_name
      @match_temp_name ||= generate_hygienic_name("__dynamic_locals_match")
    end

    # `rescue => e` has no expression form to wrap, so sync the shadow as the
    # first statement of the rescue body.
    def shadow_rescue_reference(node, scopes)
      reference = node.reference
      return unless Prism::LocalVariableTargetNode === reference
      return unless shadow_binding?(reference.name, reference.depth, scopes)

      sync = "#{shadow_name(reference.name)} = #{reference.name}"
      insert_at_body_start(node, node.then_keyword_loc, sync) do
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
      insert_at_body_start(node, node.do_keyword_loc, sync) do
        @rewriter.insert_at(node.collection.location.end_offset, " do #{sync}")
      end
    end

    # `expr => pattern` raises on mismatch, so on any fall-through the targets
    # were assigned; sync unconditionally, preserving the expression's value:
    # `begin tmp = (expr); tmp => pattern; __dynamic_locals_shadow_x = x; tmp end`
    def shadow_required_pattern(node, scopes)
      names = shadow_pattern_names(node.pattern, scopes)
      return if names.empty?

      result = generate_hygienic_name("__dynamic_locals_pattern_result")
      @rewriter.insert_before(node, "begin #{result} = (")
      @rewriter.insert_after(node.value, "); #{result}")
      @rewriter.insert_after(node, "; #{shadow_sync_src(names)}; #{result} end")
    end

    # `expr in pattern` is a boolean; sync only when it matched:
    # `(begin tmp = (expr in pattern); __dynamic_locals_shadow_x = x if tmp; tmp end)`
    def shadow_predicate_pattern(node, scopes)
      names = shadow_pattern_names(node.pattern, scopes)
      return if names.empty?

      result = generate_hygienic_name("__dynamic_locals_pattern_result")
      @rewriter.insert_before(node, "(begin #{result} = (")
      @rewriter.insert_after(
        node,
        "); #{shadow_sync_src(names)} if #{result}; #{result} end)",
      )
    end

    # A `case/in` clause's targets are assigned once its pattern matches, even
    # if a guard then rejects it, so sync at the start of the clause body -- or
    # inside the guard itself, which can already read the captures.
    def shadow_in_clause(node, scopes)
      guard = node.pattern if Prism::IfNode === node.pattern || Prism::UnlessNode === node.pattern
      pattern = guard ? guard.statements : node.pattern
      names = shadow_pattern_names(pattern, scopes)
      return yield if names.empty?

      sync = shadow_sync_src(names)
      if guard
        predicate = guard.predicate
        # Register the closing insertion after rewriting the predicate so a
        # nested pattern wrapper closes before this guard wrapper.
        @rewriter.insert_before(predicate, "(begin #{sync}; ")
        yield
        @rewriter.insert_after(predicate, " end)")
      else
        insert_at_body_start(node, node.then_loc, sync) do
          @rewriter.insert_after(node.pattern, "; #{sync};")
        end
        yield
      end
    end

    def shadow_pattern_names(pattern, scopes)
      names = []
      each_local_target(pattern) do |target|
        names << target.name if shadow_binding?(target.name, target.depth, scopes)
      end
      names.uniq
    end

    def shadow_sync_src(names)
      names.map { |name| "#{shadow_name(name)} = #{name}" }.join("; ")
    end

    # Insert +src+ as the first statement of +node+'s body. An empty body has
    # no statement to insert before, so it goes after +keyword_loc+ (the
    # node's `then`/`do`) instead; when that is also absent, yields to let the
    # caller pick a spot.
    def insert_at_body_start(node, keyword_loc, src)
      if (first = node.statements&.body&.first)
        @rewriter.insert_before(first, "#{src}; ")
      elsif keyword_loc
        @rewriter.insert_at(keyword_loc.end_offset, " #{src};")
      else
        yield
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
      return "" if keywords?
      (@local_table.sort.uniq - known_locals).map do |local|
        "#{local} = #{locals_hash}[#{local.inspect}];"
      end.join
    end

    def local_lookup_src(name, fallback)
      if keywords?
        "(#{keyword_unset_flag(name)} ? #{name}() : #{name})"
      elsif @local_table.include?(name)
        "(#{locals_hash}.key?(#{name.inspect}) ? #{name} : #{fallback})"
      else
        "#{locals_hash}.fetch(#{name.inspect}){ #{fallback} }"
      end
    end

    def defined_lookup_src(name)
      if keywords?
        "(#{keyword_unset_flag(name)} ? defined?(#{name}()) : 'local-variable'.freeze)"
      else
        "(#{locals_hash}.key?(#{name.inspect}) ? 'local-variable'.freeze : defined?(#{name}()))"
      end
    end

    def keyword_unset_flag(name)
      @keyword_unset_flags[name] ||=
        generate_hygienic_name("__dynamic_locals_unset_#{@keyword_unset_flags.length}")
    end

    def keywords?
      lookup_strategy == :keywords
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

    def defined_variable_call?(node)
      Prism::DefinedNode === node && variable_call?(node.value)
    end
  end
end
