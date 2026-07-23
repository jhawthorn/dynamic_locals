require "prism"

module DynamicLocals
  class ASTRewriter
    # The source we translate is a *method body*: it may legally use constructs
    # that are only valid inside a method -- `yield`, a top-level `return`, and
    # an implicit begin/rescue (`raise; rescue; ...`). Parsing it as a standalone
    # program rejects those, so we parse it wrapped in a method definition and
    # then map node offsets back onto the original (unwrapped) source.
    WRAPPER_NAME = "__dynamic_locals_parse_wrapper__"
    WRAPPER_PREFIX = "def #{WRAPPER_NAME}\n"
    WRAPPER_SUFFIX = "\nend"

    def initialize(source)
      @original_src = source.dup.freeze

      result, prefix = parse_with_locals([])
      errors = result.errors.reject { |error| error.type == :no_local_variable }
      raise SyntaxError, errors.map(&:message).join("\n") if errors.any?

      # A pin such as `^foo` reports :no_local_variable when `foo` will only be
      # supplied dynamically. Reparse with those names declared on the wrapper
      # method; pins in blocks then resolve naturally, while a pin beyond a real
      # scope boundary (a nested def/class/module body) remains a syntax error.
      implicit_locals = result.errors.filter_map do |error|
        error.location.slice.to_sym if error.type == :no_local_variable
      end.uniq
      result, prefix = parse_with_locals(implicit_locals) if implicit_locals.any?
      raise SyntaxError, result.errors.map(&:message).join("\n") unless result.success?

      @offset = prefix.bytesize
      @def_node = result.value.statements.body.first
      @replacements = []
    end

    Replacement = Struct.new(:range, :src)

    attr_reader :original_src

    # The method body scope: a StatementsNode, a BeginNode (when the body has a
    # rescue/else/ensure), or nil when the body is empty.
    def ast
      @def_node.body
    end

    # The method-level local table Ruby derives from the body.
    def locals
      @def_node.locals
    end

    def modified_src
      # Apply right-to-left so earlier ranges stay valid. Ties are broken so
      # that a zero-width insertion at an offset is applied before a
      # replacement ending there (keeping the insertion outside the replaced
      # text), and same-position insertions land in registration order.
      rewrites =
        @replacements.each_with_index.sort_by do |replacement, index|
          [replacement.range.end, replacement.range.begin, index]
        end.reverse

      src = original_src.b
      rewrites.each do |replacement, _|
        src[replacement.range] = replacement.src.b
      end
      src.force_encoding(original_src.encoding)
    end
    alias_method :src, :modified_src

    def insert_before(node, src)
      raise TypeError unless Prism::Node === node

      insert_at(node.location.start_offset, src)
    end

    def insert_after(node, src)
      raise TypeError unless Prism::Node === node

      insert_at(node.location.end_offset, src)
    end

    # Offsets are relative to the wrapped source, as in Prism locations.
    def insert_at(wrapped_offset, src)
      pos = wrapped_offset - @offset
      @replacements << Replacement.new(pos...pos, src)
    end

    def replace_offsets(wrapped_start, wrapped_end, src)
      @replacements << Replacement.new((wrapped_start - @offset)...(wrapped_end - @offset), src)
    end

    def replace(node, src)
      raise TypeError unless Prism::Node === node

      range = range_from(node)
      @replacements << Replacement.new(range, src)
    end

    private

    def parse_with_locals(locals)
      prefix =
        if locals.empty?
          WRAPPER_PREFIX
        else
          parameters = locals.map { |local| "#{local}: nil" }.join(", ")
          "def #{WRAPPER_NAME}(#{parameters})\n"
        end
      [Prism.parse("#{prefix}#{@original_src}#{WRAPPER_SUFFIX}"), prefix]
    end

    # Node offsets are relative to the wrapped source; shift them back onto the
    # original source by subtracting the wrapper prefix length.
    def range_from(node)
      (node.location.start_offset - @offset)...(node.location.end_offset - @offset)
    end
  end
end
