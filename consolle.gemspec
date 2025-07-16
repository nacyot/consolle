# frozen_string_literal: true

require_relative "lib/consolle/version"

Gem::Specification.new do |spec|
  spec.name          = "consolle"
  spec.version       = Consolle::VERSION
  spec.authors       = ["nacyot"]
  spec.email         = ["propellerheaven@gmail.com"]

  spec.summary       = "PTY-based Rails console management library"
  spec.description   = "Consolle is a library that manages Rails console through PTY (Pseudo-Terminal). Moving away from the traditional eval-based execution method, it manages the actual Rails console process as a subprocess to provide a more stable and secure execution environment."
  spec.homepage      = "https://consolle.nacyot.com"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.pkg.github.com/nacyot"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/nacyot/consolle"
  spec.metadata["changelog_uri"] = "https://github.com/nacyot/consolle/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features)/}) }
  end
  spec.bindir        = "bin"
  spec.executables   = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "thor", "~> 1.0"
  spec.add_dependency "logger", "~> 1.0"

  # Development dependencies
  spec.add_development_dependency "rspec", "~> 3.0"
end