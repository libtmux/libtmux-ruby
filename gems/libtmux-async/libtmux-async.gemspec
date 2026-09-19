# frozen_string_literal: true

require_relative "lib/libtmux/async/version"

Gem::Specification.new do |spec|
  spec.name = "libtmux-async"
  spec.version = LibTmux::Async::VERSION
  spec.authors = ["libtmux contributors"]
  spec.summary = "Optional Async integration for libtmux"
  spec.description = "Optional Async integration for libtmux; unreleased implementation in progress."
  spec.homepage = "https://github.com/libtmux/libtmux-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = { "source_code_uri" => spec.homepage }
  spec.require_paths = ["lib"]
  spec.files = %w[
    LICENSE README.md
    lib/libtmux/async.rb
    lib/libtmux/async/version.rb
    lib/libtmux/async/process.rb
    lib/libtmux/async/scope.rb
    lib/libtmux/async/server.rb
    lib/libtmux/async/control.rb
    sig/libtmux-async.rbs
  ]
  spec.add_dependency "libtmux", "= 0.1.0.pre"
  spec.add_dependency "async", "~> 2.46.0"
end
