require "dynamic_locals/version"
require "dynamic_locals/eval_translator"
require "dynamic_locals/rewrite_translator"

module DynamicLocals
  class Error < StandardError; end

  def self.translate(src)
    DynamicLocals::EvalTranslator.translate(src)
  end
end
