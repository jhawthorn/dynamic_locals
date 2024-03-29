
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "dynamic_locals/version"

Gem::Specification.new do |spec|
  spec.name          = "dynamic_locals"
  spec.version       = DynamicLocals::VERSION
  spec.authors       = ["John Hawthorn"]
  spec.email         = ["john@hawthorn.email"]

  spec.summary       = %q{Makes it possible to define locals dynamically}
  spec.description   = %q{Parses ruby to rewrite how locals work}
  spec.homepage      = "https://github.com/jhawthorn/dynamic_locals"
  spec.license       = "MIT"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
end
