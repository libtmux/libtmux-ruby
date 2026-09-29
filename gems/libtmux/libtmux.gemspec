# frozen_string_literal: true

require_relative "lib/libtmux/version"

Gem::Specification.new do |spec|
  spec.name = "libtmux"
  spec.version = LibTmux::VERSION
  spec.authors = ["libtmux contributors"]
  spec.summary = "Ruby tmux orchestration core"
  spec.description = "Manage tmux sessions, windows and panes with Ruby handles, immutable snapshots and control connections."
  spec.homepage = "https://github.com/libtmux/libtmux-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "documentation_uri" => "https://libtmux.org/en/ruby/v#{spec.version}/"
  }
  spec.require_paths = ["lib"]
  spec.files = %w[
    LICENSE README.md
    assets/logo.svg assets/logo.png
    lib/libtmux.rb
    lib/libtmux/version.rb
    lib/libtmux/errors.rb
    lib/libtmux/process.rb
    lib/libtmux/child.rb
    lib/libtmux/endpoint.rb
    lib/libtmux/metadata.rb
    lib/libtmux/selection.rb
    lib/libtmux/entity.rb
    lib/libtmux/server.rb
    lib/libtmux/operations.rb
    lib/libtmux/options.rb
    lib/libtmux/catalog.rb
    lib/libtmux/snapshot.rb
    lib/libtmux/capture.rb
    lib/libtmux/source_query.rb
    lib/libtmux/control.rb
    lib/libtmux/group.rb
    lib/libtmux/owned.rb
    lib/libtmux/socket_readiness.rb
    lib/libtmux/terminal.rb
    lib/libtmux/criteria.rb
    lib/libtmux/process_wait.rb
    sig/libtmux.rbs
    sig/criteria.rbs
    sig/operations.rbs
    sig/snapshot.rbs
    sig/control.rbs
    sig/group.rbs
    sig/owned.rbs
    sig/terminal.rbs
    sig/fields.rbs
    schema/where-v1.json
  ]
  # Default gems (json, tmpdir, securerandom, io-console) load from every
  # supported Ruby without a declaration. fiddle is a bundled gem from Ruby 4.0,
  # so Bundler needs it declared.
  spec.add_dependency "fiddle", "~> 1.1"
end
