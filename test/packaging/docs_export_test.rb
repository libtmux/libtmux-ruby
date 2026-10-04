# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "tmpdir"

class DocsExportTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_export_covers_the_public_inventory_without_machine_paths
    load File.join(ROOT, "scripts/export-docs") unless defined?(DocumentationExport)
    payload = DocumentationExport.new(ROOT).payload
    packages = payload.fetch("packages")
    namespaces = payload.fetch("namespaces")
    symbols = payload.fetch("symbols")
    aliases = payload.fetch("aliases")

    assert_equal 1, payload.fetch("schema")
    assert_match(/\A[0-9a-f]{40}\z/, payload.dig("source", "revision"))
    assert_equal %w[libtmux libtmux-async libtmux-mcp libtmux-workspace],
                 packages.map { |entry| entry.fetch("name") }
    assert_equal PublicAPI.new.exports.map(&:name).sort,
                 namespaces.map { |entry| entry.fetch("id") }
    assert namespaces.any? { |entry|
             entry.fetch("id") == "LibTmux::Server" && entry.fetch("kind") == "class"
           }
    expected_paths = {
      "libtmux" => "",
      "libtmux-async" => "reference/",
      "libtmux-mcp" => "mcp/",
      "libtmux-workspace" => "workspace/"
    }
    packages.each do |entry|
      name = entry.fetch("name")
      spec = Gem::Specification.find_by_name(name)
      assert_equal "https://libtmux.org/en/ruby/v#{spec.version}/#{expected_paths.fetch(name)}",
                   spec.metadata.fetch("documentation_uri")
    end
    assert_equal PublicAPI.new.records.map { |record| record.fetch("id") },
                 symbols.map { |symbol| symbol.fetch("id") }
    assert_equal symbols.length, symbols.map { |symbol| symbol.fetch("id") }.uniq.length
    assert symbols.all? { |symbol| symbol.dig("source", "path").start_with?("gems/") }
    assert symbols.all? { |symbol| symbol.fetch("visibility") == "public" }
    assert_includes packages.find { |entry| entry.fetch("name") == "libtmux-async" }.fetch("rbs"),
                    "scope_diagnostics"
    assert_equal ["LibTmux::Async::scope_diagnostics"], aliases.map { |entry| entry.fetch("id") }
    assert_equal "libtmux-async", aliases.first.fetch("package")
    refute_match(%r{/(?:home|Users)/}, JSON.generate(payload))
  end

  def test_serialization_is_deterministic
    load File.join(ROOT, "scripts/export-docs") unless defined?(DocumentationExport)
    export = DocumentationExport.new(ROOT)
    assert_equal export.to_json, export.to_json
  end

  def test_api_examples_retain_complete_file_bytes_and_resolve_public_package_targets
    load File.join(ROOT, "scripts/export-docs") unless defined?(DocumentationExport)
    payload = DocumentationExport.new(ROOT).payload
    examples = payload.fetch("examples")
    programs = examples.fetch("manifest").fetch("programs").select { |entry| entry.key?("api") }
    files = examples.fetch("files").to_h { |entry| [entry.fetch("path"), entry.fetch("content")] }
    public =
      (payload.fetch("namespaces") + payload.fetch("symbols")).to_h do |entry|
        [entry.fetch("id"), entry.fetch("package")]
      end
    assert_equal 8, programs.length
    programs.each do |program|
      code = files.fetch(program.fetch("path"))
      assert_equal File.read(File.join(ROOT, program.fetch("path"))), code
      assert_includes code, 'require "libtmux"'
      refute_includes code, "require_relative"
      program
        .fetch("api")
        .fetch("symbols")
        .each { |id| assert_equal program.fetch("gem"), public.fetch(id) }
    end

    Dir.mktmpdir("libtmux-ruby-api-export-") do |directory|
      manifest = ExampleManifest.new(ROOT)
      invalid = Marshal.load(Marshal.dump(manifest.data))
      invalid.fetch("programs").find { |entry| entry.key?("api") }.fetch("api")["symbols"] = [
        "LibTmux::Server#does_not_exist"
      ]
      FileUtils.cp_r(File.join(ROOT, "examples"), directory)
      invalid
        .fetch("documents")
        .each do |path|
          target = File.join(directory, path)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(File.join(ROOT, path), target)
        end
      FileUtils.cp(
        File.join(ROOT, "docs/reference/contracts.json"),
        File.join(directory, "docs/reference/contracts.json")
      )
      File.write(File.join(directory, "examples", "manifest.json"), JSON.generate(invalid))
      export = DocumentationExport.new(directory)
      export.define_singleton_method(:revision) { "a" * 40 }
      failure = assert_raises(DocumentationExport::Error) { export.payload }
      assert_match(/unknown API example target/, failure.message)
      invalid.fetch("programs").find { |entry| entry.key?("api") }.fetch("api")["symbols"] = [
        "LibTmux::Async::Server"
      ]
      File.write(File.join(directory, "examples", "manifest.json"), JSON.generate(invalid))
      failure = assert_raises(DocumentationExport::Error) { export.payload }
      assert_match(/API example package differs/, failure.message)
    end
  end
end
