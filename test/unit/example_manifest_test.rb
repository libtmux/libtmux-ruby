# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

class ExampleManifestTest < Minitest::Test
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
end
