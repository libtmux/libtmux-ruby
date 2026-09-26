# frozen_string_literal: true

require_relative "lib/libtmux/mcp/version"

Gem::Specification.new do |spec|
  spec.name = "libtmux-mcp"
  spec.version = LibTmux::MCP::VERSION
  spec.authors = ["libtmux contributors"]
  spec.summary = "MCP consumer package for libtmux"
  spec.description = "Expose tmux snapshots, captures and explicitly enabled mutations through an MCP stdio server."
  spec.homepage = "https://github.com/libtmux/libtmux-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "documentation_uri" => "https://libtmux.org/en/ruby/v#{spec.version}/mcp/"
  }
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["libtmux-mcp"]
  spec.files = %w[
    LICENSE README.md
    exe/libtmux-mcp
    lib/libtmux/mcp.rb
    lib/libtmux/mcp/version.rb
    lib/libtmux/mcp/stdio_transport.rb
    lib/libtmux/mcp/catalog.rb
    lib/libtmux/mcp/catalog_tool.rb
    lib/libtmux/mcp/application.rb
    lib/libtmux/mcp/mutations.rb
    lib/libtmux/mcp/resources.rb
    lib/libtmux/mcp/observation.rb
    lib/libtmux/mcp/process_identity.rb
    lib/libtmux/mcp/enrollment.rb
    lib/libtmux/mcp/shell/integration.zsh
    lib/libtmux/mcp/shell/prepare.rb
    lib/libtmux/mcp/cli.rb
    sig/libtmux-mcp.rbs
    sig/transport.rbs
  ]
  spec.add_dependency "libtmux", "= #{spec.version}"
  spec.add_dependency "libtmux-async", "= #{spec.version}"
  spec.add_dependency "mcp", "~> 1.5.1"
  spec.add_dependency "digest", "~> 3.2.1"
  spec.add_dependency "optparse", ">= 0.4", "< 1"
end
