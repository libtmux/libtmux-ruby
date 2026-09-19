# frozen_string_literal: true

require_relative "lib/libtmux/workspace/version"

Gem::Specification.new do |spec|
  spec.name = "libtmux-workspace"
  spec.version = LibTmux::Workspace::VERSION
  spec.authors = ["libtmux contributors"]
  spec.summary = "Data-only workspace consumer package for libtmux"
  spec.description = "Data-only workspace consumer package for libtmux; unreleased implementation in progress."
  spec.homepage = "https://github.com/libtmux/libtmux-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = { "source_code_uri" => spec.homepage }
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["libtmux-workspace"]
  spec.files = %w[
    LICENSE README.md
    exe/libtmux-workspace
    lib/libtmux/workspace.rb
    lib/libtmux/workspace/apply.rb
    lib/libtmux/workspace/cli.rb
    lib/libtmux/workspace/document.rb
    lib/libtmux/workspace/normalizer.rb
    lib/libtmux/workspace/plan.rb
    lib/libtmux/workspace/version.rb
    sig/libtmux-workspace.rbs
  ]
  spec.add_dependency "libtmux", "= 0.1.0.pre"
  spec.add_dependency "json", "~> 3.0.2"
  spec.add_dependency "psych", "~> 5.5.0"
end
