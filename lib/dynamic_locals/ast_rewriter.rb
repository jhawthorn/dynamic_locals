require "prism"

module DynamicLocals
  class ASTRewriter
    # The source we translate is a *method body*: it may legally use constructs
    # that are only valid inside a method -- `yield`, a top-level `return`, and
    # an implicit begin/rescue (`raise; rescue; ...`). Parsing it as a standalone
    # program rejects those, so we parse it wrapped in a method definition and
    # then map node offsets back onto the original (unwrapped) source.
    WRAPPER_PREFIX = "def __dynamic_locals_parse_wrapper__\n"
    WRAPPER_SUFFIX = "\nend"

    def initialize(source)
      @original_src = source.dup.freeze
      @offset = WRAPPER_PREFIX.bytesize

      wrapped = "#{WRAPPER_PREFIX}#{@original_src}#{WRAPPER_SUFFIX}"
      result = Prism.parse(wrapped)
      raise SyntaxError, result.errors.map(&:message).join("\n") unless result.success?

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
      rewrites = @replacements
      rewrites =
        rewrites.sort_by do |replacement|
          replacement.range.end
        end.reverse

      src = original_src.b
      rewrites.each do |replacement|
        src[replacement.range] = replacement.src.b
      end
      src.force_encoding(original_src.encoding)
    end
    alias_method :src, :modified_src

    def insert_before(node, src)
      raise TypeError unless Prism::Node === node

      start = range_from(node).begin
      range = start...start
      @replacements << Replacement.new(range, src)
    end

    def replace(node, src)
      raise TypeError unless Prism::Node === node

      range = range_from(node)
      @replacements << Replacement.new(range, src)
    end

    private

    # Node offsets are relative to the wrapped source; shift them back onto the
    # original source by subtracting the wrapper prefix length.
    def range_from(node)
      (node.location.start_offset - @offset)...(node.location.end_offset - @offset)
    end
  end
end
