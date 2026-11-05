# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "open3"

class ExampleManifestTest < Minitest::Test
  def test_api_examples_require_unique_targets_description_and_expected_output
    path = File.expand_path("../../scripts/examples", __dir__)
    load path unless defined?(ExampleManifest)
    Dir.mktmpdir("libtmux-ruby-api-manifest-") do |root|
      FileUtils.mkdir_p(File.join(root, "examples"))
      File.write(File.join(root, "examples", "one.rb"), "require 'libtmux'\nputs :one\n")
      manifest = {"version" => 1,
        "programs" => [{"id" => "one", "path" => "examples/one.rb", "gem" => "libtmux",
          "api" => {"symbols" => ["LibTmux::Server", "LibTmux::Server.new"],
                    "description" => "Connect to a server.", "output" => "one\n"}}],
        "support" => [], "documents" => [], "snippets" => []}
      File.write(File.join(root, "examples", "manifest.json"), JSON.generate(manifest))
      checker = ExampleManifest.new(root)
      assert checker.check
      original = checker.data.fetch("programs").first.fetch("api")
      [nil, {}, original.merge("symbols" => []), original.merge("symbols" => [" "]),
        original.merge("symbols" => ["LibTmux::Server", "LibTmux::Server"]),
        original.merge("description" => " "), original.merge("output" => ""),
        original.merge("output" => "one")].each do |invalid|
        checker.data.fetch("programs").first["api"] = invalid
        assert_raises(ExampleManifest::Error) { checker.check }
      end
      checker.data.fetch("programs").first["api"] = original
      File.write(File.join(root, "examples", "two.rb"), "puts :two\n")
      checker.data.fetch("programs") << {"id" => "two", "path" => "examples/two.rb",
        "gem" => "libtmux", "api" => original}
      failure = assert_raises(ExampleManifest::Error) { checker.check }
      assert_match(/duplicate API targets/, failure.message)
    end
  end

  def test_api_capabilities_must_resolve_and_cover_the_symbols_the_program_documents
    path = File.expand_path("../../scripts/examples", __dir__)
    load path unless defined?(ExampleManifest)
    Dir.mktmpdir("libtmux-ruby-api-capabilities-") do |root|
      FileUtils.mkdir_p(File.join(root, "examples"))
      File.write(File.join(root, "examples", "one.rb"), "require 'libtmux'\nputs :one\n")
      manifest = {"version" => 2,
        "programs" => [{"id" => "one", "path" => "examples/one.rb", "gem" => "libtmux",
          "api" => {"symbols" => ["LibTmux::Server#open_control"],
                    "description" => "Open a control connection.", "output" => "one\n"}}],
        "support" => [], "documents" => [], "snippets" => []}
      File.write(File.join(root, "examples", "manifest.json"), JSON.generate(manifest))
      checker = ExampleManifest.new(root)
      entry = checker.data.fetch("programs").first
      api = entry.fetch("api")
      declare = lambda do |symbols, capabilities|
        api["symbols"] = symbols
        capabilities ? api["capabilities"] = capabilities : api.delete("capabilities")
        checker
      end

      # A program that opens a control connection must declare control-mode.
      failure = assert_raises(ExampleManifest::Error) { declare.call(["LibTmux::Server#open_control"], nil).check }
      assert_equal "API example one uses a capability it does not declare: control-mode", failure.message
      assert declare.call(["LibTmux::Server#open_control"], ["control-mode"]).check
      assert_equal "3.7", checker.tmux_release(entry)
      assert declare.call(["LibTmux::Async::Server#open_control"], ["control-mode"]).check

      # An id the registry lacks fails, and a typo does not pass as a near match.
      failure = assert_raises(ExampleManifest::Error) { declare.call(["LibTmux::Server#open_control"], ["control-modes"]).check }
      assert_equal "unknown capability in API example one: control-modes", failure.message

      # A program can need a capability through a symbol it does not document,
      # such as a second control example whose page is ControlConnection#exchange;
      # the packaging run expects it to be refused on a tmux without it.
      assert declare.call(["LibTmux::ControlConnection#exchange"], ["control-mode"]).check
      assert_equal "3.7", checker.tmux_release(entry)

      # A typed gate that refuses on every call is required, not merely allowed.
      failure = assert_raises(ExampleManifest::Error) { declare.call(["LibTmux::Server#delete_buffer"], nil).check }
      assert_match(/uses a capability it does not declare: buffer-delete-named\z/, failure.message)

      # A raw command channel reaches several gates and the manifest cannot see
      # which command is sent: declaring none passes, and declaring one it can reach passes.
      assert declare.call(["LibTmux::Server#run"], nil).check
      assert_equal "3.3a", checker.tmux_release(entry)
      assert declare.call(["LibTmux::Server#run"], ["clipboard-query"]).check
      assert_equal "3.6a", checker.tmux_release(entry)
      assert declare.call(["LibTmux::Server#run"], %w[clipboard-query layout-json]).check
      assert_equal "3.8", checker.tmux_release(entry)

      # The key is optional, but present it is a non-empty list of unique strings.
      [[], ["control-mode", "control-mode"], [nil], "control-mode", [7]].each do |invalid|
        failure = assert_raises(ExampleManifest::Error) { declare.call(["LibTmux::Server#open_control"], invalid).check }
        assert_equal "invalid API example capabilities: one", failure.message
      end
    end
  end

  def test_a_version_1_manifest_is_read_as_it_was_written
    path = File.expand_path("../../scripts/examples", __dir__)
    load path unless defined?(ExampleManifest)
    Dir.mktmpdir("libtmux-ruby-api-capabilities-") do |root|
      FileUtils.mkdir_p(File.join(root, "examples"))
      File.write(File.join(root, "examples", "one.rb"), "require 'libtmux'\nputs :one\n")
      api = {"symbols" => ["LibTmux::Server#open_control"], "description" => "Open a control connection.", "output" => "one\n"}
      write = lambda do |version, extra|
        manifest = {"version" => version, "programs" => [{"id" => "one", "path" => "examples/one.rb", "gem" => "libtmux", "api" => api.merge(extra)}],
          "support" => [], "documents" => [], "snippets" => []}
        File.write(File.join(root, "examples", "manifest.json"), JSON.generate(manifest))
        ExampleManifest.new(root)
      end
      # A release cut before the field documents its control program without one;
      # a docs rebuild of that release still exports, at the floor it stated then.
      legacy = write.call(1, {})
      assert legacy.check
      assert_equal ExampleManifest.releases::MINIMUM, legacy.tmux_release(legacy.data.fetch("programs").first)
      failure = assert_raises(ExampleManifest::Error) { write.call(1, {"capabilities" => ["control-mode"]}).check }
      assert_equal "API example capabilities need manifest version 2: one", failure.message
      failure = assert_raises(ExampleManifest::Error) { write.call(2, {}).check }
      assert_equal "API example one uses a capability it does not declare: control-mode", failure.message
    end
  end

  def test_the_committed_control_examples_declare_control_mode_and_state_tmux_3_7
    path = File.expand_path("../../scripts/examples", __dir__)
    load path unless defined?(ExampleManifest)
    checker = ExampleManifest.new(File.expand_path("../..", __dir__))
    assert checker.check
    programs = checker.data.fetch("programs").select { |entry| entry.key?("api") }
    releases = programs.to_h { |entry| [entry.fetch("path"), checker.tmux_release(entry)] }
    control = %w[examples/api/control.rb examples/api/async_control.rb]
    control.each do |program|
      assert_equal ["control-mode"], programs.find { |entry| entry["path"] == program }.dig("api", "capabilities")
      assert_equal "3.7", releases.fetch(program)
    end
  end

  def test_a_version_1_manifest_is_checked_without_the_capability_registry
    # A docs rebuild of a release from before the registry runs with that
    # release's library loaded, which defines no Capabilities.
    script = File.expand_path("../../scripts/examples", __dir__)
    Dir.mktmpdir("libtmux-ruby-api-legacy-") do |root|
      FileUtils.mkdir_p(File.join(root, "examples"))
      File.write(File.join(root, "examples", "one.rb"), "require 'libtmux'\nputs :one\n")
      api = {"symbols" => ["LibTmux::Server#open_control"], "description" => "Open a control connection.", "output" => "one\n"}
      manifest = {"version" => 1, "programs" => [{"id" => "one", "path" => "examples/one.rb", "gem" => "libtmux", "api" => api}],
        "support" => [], "documents" => [], "snippets" => []}
      File.write(File.join(root, "examples", "manifest.json"), JSON.generate(manifest))
      code = "module LibTmux; module Internal; end; end; load ARGV[0]; ExampleManifest.new(ARGV[1]).check; " \
        "puts defined?(LibTmux::Internal::Capabilities).inspect"
      output, status = Open3.capture2e(Gem.ruby, "-e", code, script, root)
      assert status.success?, output
      assert_equal "nil\n", output
    end
  end

  def test_the_conditional_apis_are_the_registry_channels_and_select_layout
    path = File.expand_path("../../scripts/examples", __dir__)
    load path unless defined?(ExampleManifest)
    registry = ExampleManifest.registry
    expected = registry::RUN_CHANNELS + registry::CONTROL_CHANNELS + ["LibTmux::Window#select_layout"]
    assert_equal expected.sort, ExampleManifest::CONDITIONAL_APIS.sort
  end

  def test_rendered_links_require_a_real_destination_and_fragment
    path = File.expand_path("../../scripts/docs", __dir__)
    assert File.file?(path), "rendered documentation checker is missing"
    load path unless defined?(DocumentationSite)
    Dir.mktmpdir("libtmux-ruby-links-") do |directory|
      File.write(File.join(directory, "index.html"), '<a href="target.html#missing">target</a>')
      failure = assert_raises(DocumentationSite::Error) { DocumentationSite.validate(directory) }
      assert_match(/missing destination/, failure.message)
      File.write(File.join(directory, "target.html"), '<h1 id="present">Title</h1>')
      failure = assert_raises(DocumentationSite::Error) { DocumentationSite.validate(directory) }
      assert_match(/missing fragment/, failure.message)
      File.write(File.join(directory, "index.html"), '<a href="target.html#present">target</a>')
      assert_equal 2, DocumentationSite.validate(directory)
    end
  end

  def test_discovery_rejects_an_unlisted_program_and_a_changed_documented_excerpt
    path = File.expand_path("../../scripts/examples", __dir__)
    assert File.file?(path), "executable-example discovery checker is missing"
    load path unless defined?(ExampleManifest)
    Dir.mktmpdir("libtmux-ruby-manifest-") do |root|
      FileUtils.mkdir_p(File.join(root, "examples"))
      File.write(File.join(root, "examples", "one.rb"), "# docs:begin main\nputs :one\n# docs:end main\n")
      File.write(File.join(root, "README.md"), "<!-- example: one/main -->\n```ruby\nputs :one\n```\n<!-- /example -->\n")
      manifest = {"version" => 1, "programs" => [{"id" => "one", "path" => "examples/one.rb", "gem" => "libtmux"}],
        "support" => [], "documents" => ["README.md"], "snippets" => [{"id" => "one/main", "source" => "examples/one.rb", "region" => "main", "language" => "ruby"}]}
      File.write(File.join(root, "examples", "manifest.json"), JSON.generate(manifest))
      checker = ExampleManifest.new(root)
      assert checker.check
      checker.data.fetch("programs").first["gem"] = "not-installed"
      failure = assert_raises(ExampleManifest::Error) { checker.check }
      assert_match(/unknown package/, failure.message)
      checker.data.fetch("programs").first["gem"] = "libtmux"
      File.write(File.join(root, "examples", "forgotten.rb"), "puts :forgotten\n")
      failure = assert_raises(ExampleManifest::Error) { checker.check }
      assert_match(/unlisted/, failure.message)
      File.unlink(File.join(root, "examples", "forgotten.rb"))
      File.write(File.join(root, "README.md"), "<!-- example: one/main -->\n```ruby\nputs :different\n```\n<!-- /example -->\n")
      failure = assert_raises(ExampleManifest::Error) { checker.check }
      assert_match(/excerpt differs/, failure.message)
    end
  end

  def test_the_workspace_example_writes_the_example_workspace_file
    root = File.expand_path("../..", __dir__)
    program = File.read(File.join(root, "examples/api/workspace_apply.rb"))
    document = program[/<<~'YAML'\n(.*?)^\s*YAML\n/m, 1]
    refute_nil document
    indentation = document.lines.map { |line| line[/\A */].size }.min
    assert_equal File.read(File.join(root, "examples/workspace.yaml")), document.lines.map { |line| line[indentation..] }.join
  end
end
