require "dynamic_locals/version"
require "dynamic_locals/base_translator"
require "dynamic_locals/eval_translator"
require "dynamic_locals/rewrite_translator"

module DynamicLocals
  class Error < StandardError; end

  DefaultImplementation = RewriteTranslator

  def self.translate(...)
    DefaultImplementation.new(...).translate
  end

  # This is intended for convenience debugging purposes
  def self.compile(...)
    eval("-> (locals = {}) { #{translate(...)} }")
  end
end
