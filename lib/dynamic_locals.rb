require "dynamic_locals/version"
require "dynamic_locals/eval_translator"
require "dynamic_locals/rewrite_translator"

module DynamicLocals
  class Error < StandardError; end

  DefaultImplementation = RewriteTranslator

  def self.translate(src)
    DefaultImplementation.translate(src)
  end
end
