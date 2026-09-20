# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "digest"
require "net/http"

load File.expand_path("../../scripts/release.rb", __dir__) unless defined?(GemRelease)

module ReleaseHTTP
  def with_http(responses)
    original = Net::HTTP.method(:start)
    connection = Object.new
    connection.define_singleton_method(:get) do |path|
      code, body = responses.fetch(path)
      response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "fixture")
      response.body = body
      response.instance_variable_set(:@read, true)
      response
    end
    Net::HTTP.define_singleton_method(:start) do |host, port, **options, &block|
      raise "unexpected registry origin" unless host == "rubygems.org" && port == 443 && options[:use_ssl]
      block.call(connection)
    end
    yield GemRelease.const_get(:RubyGemsRegistry).new
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end
end

class ReleaseTest < Minitest::Test
  include ReleaseHTTP
  NAMES = %w[libtmux libtmux-async libtmux-mcp libtmux-workspace].freeze
  VERSION = "0.1.0.alpha.1"

  class << self
    attr_accessor :source_fixture, :source_commit
  end

  class Registry
    attr_reader :versions, :pushes, :lookups
    attr_accessor :fail_name, :unconfirmed, :lookup_error

    def initialize
      @versions = {}
      @pushes = []
      @lookups = []
    end

    def version_sha(name, version)
      @lookups << [name, version]
      raise GemRelease::Error, "simulated network failure" if name == lookup_error
      @versions[name]
    end

    def push(path, env:)
      name = File.basename(path).delete_suffix("-#{VERSION}.gem")
      raise GemRelease::Error, "simulated upload failure" if name == fail_name
      @pushes << name
      @versions[name] = Digest::SHA256.file(path).hexdigest unless unconfirmed
    end
  end

  def setup
    @root = Dir.mktmpdir("libtmux-ruby-release-")
    if self.class.source_fixture
      FileUtils.cp_r(File.join(self.class.source_fixture, "."), @root)
    else
      build_source_fixture
      self.class.source_fixture = Dir.mktmpdir("libtmux-ruby-release-source-")
      self.class.source_commit = git("rev-parse", "HEAD").strip
      FileUtils.cp_r(File.join(@root, "."), self.class.source_fixture)
      fixture = self.class.source_fixture
      Minitest.after_run { FileUtils.remove_entry(fixture) }
    end
    @commit = self.class.source_commit
    @tag = "v#{VERSION}"
    @registry = Registry.new
    @release = GemRelease.new(@root, registry: @registry)
    @env = {"GITHUB_ACTIONS" => "true", "GITHUB_EVENT_NAME" => "push",
      "GITHUB_REPOSITORY" => "libtmux/libtmux-ruby", "GITHUB_REF" => "refs/tags/#{@tag}",
      "GITHUB_SHA" => @commit,
      "GITHUB_WORKFLOW_REF" => "libtmux/libtmux-ruby/.github/workflows/release.yml@refs/tags/#{@tag}"}
  end

  def build_source_fixture
    File.write(File.join(@root, ".gitignore"), "/pkg/\n")
    NAMES.each do |name|
      directory = File.join(@root, "gems", name)
      FileUtils.mkdir_p(File.join(directory, "lib"))
      File.write(File.join(directory, "lib", "version.rb"), "module #{constant(name)}; VERSION = '#{VERSION}'; end\n")
      siblings = name == "libtmux" ? [] : ["libtmux"]
      siblings << "libtmux-async" if name == "libtmux-mcp"
      File.write(File.join(directory, "#{name}.gemspec"), <<~RUBY)
        require_relative "lib/version"
        Gem::Specification.new do |s|
          s.name = #{name.inspect}
          s.version = #{constant(name)}::VERSION
          s.authors = ["Contributors"]
          s.summary = "Release fixture"
          s.description = "Small real gem for release verification"
          s.required_ruby_version = ">= 3.3"
          s.license = "MIT"
          s.homepage = "https://example.org"
          s.files = ["lib/version.rb"]
          #{siblings.map { |sibling| "s.add_dependency #{sibling.inspect}, '= #{VERSION}'" }.join("\n")}
        end
      RUBY
    end
    git("init", "-q")
    git("add", ".")
    git("-c", "user.name=Release Test", "-c", "user.email=release@example.invalid", "commit", "-qm", "fixture")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def test_prepare_reuses_complete_bytes_and_verify_is_local
    manifest = prepare
    assert_equal NAMES, manifest.fetch("artifacts").map { |entry| entry.fetch("name") }
    assert_equal VERSION, manifest.fetch("version")
    before = retained_bytes
    assert_equal manifest, GemRelease.new(@root).verify(tag: @tag, commit: @commit)
    alias_path = File.join(@root, "pkg/source")
    File.symlink(@root, alias_path)
    assert_equal manifest, GemRelease.new(alias_path).verify(tag: @tag, commit: @commit)
    assert_equal manifest, prepare
    assert_equal before, retained_bytes
    assert_empty @registry.lookups
    assert_empty @registry.pushes
  end

  def test_source_binding_rejects_wrong_tag_commit_dirty_files_and_sibling_dependencies
    ["#{VERSION}", "v0.1.0", "v../#{VERSION}"].each do |tag|
      assert_raises(GemRelease::Error) { @release.prepare(tag: tag, commit: @commit) }
    end
    assert_raises(GemRelease::Error) { @release.prepare(tag: @tag, commit: "0" * 40) }
    File.write(File.join(@root, "untracked"), "dirty")
    assert_raises(GemRelease::Error) { prepare }
    File.unlink(File.join(@root, "untracked"))
    path = File.join(@root, "gems/libtmux-async/libtmux-async.gemspec")
    File.write(path, File.read(path).sub("= #{VERSION}", ">= #{VERSION}"))
    assert_raises(GemRelease::Error) { prepare }
    commit_changes
    error = assert_raises(GemRelease::Error) { prepare }
    assert_match(/dependenc/i, error.message)
  end

  def test_verify_rejects_partial_extra_corrupt_and_manifest_traversal_without_rebuilding
    prepare
    original = retained_bytes
    changes = [
      -> { File.unlink(artifact) },
      -> { File.write(File.join(release_dir, "extra.gem"), "extra") },
      -> { File.write(artifact, "corrupt") },
      -> { change_manifest { |m| m["commit"] = "0" * 40 } },
      -> { change_manifest { |m| m["artifacts"][0]["filename"] = "../outside.gem" } },
      -> { change_manifest { |m| m["artifacts"] = [] } }
    ]
    changes.each do |change|
      FileUtils.rm_rf(release_dir)
      FileUtils.mkdir_p(release_dir)
      original.each { |name, bytes| File.binwrite(File.join(release_dir, name), bytes) }
      change.call
      before = retained_bytes
      assert_raises(GemRelease::Error) { @release.verify(tag: @tag, commit: @commit) }
      assert_raises(GemRelease::Error) { prepare }
      assert_equal before, retained_bytes
    end
  end

  def test_archive_must_match_source_even_with_recomputed_checksums_and_manifest_digest
    prepare
    original_archive = File.binread(artifact)
    path = File.join(@root, "gems/libtmux/lib/version.rb")
    original = File.binread(path)
    File.write(path, original + "# tampered\n")
    spec = Gem::Package.new(artifact).spec
    capture_io do
      Dir.chdir(File.dirname(File.dirname(path))) { Gem::Package.build(spec, false, true, artifact) }
    end
    File.binwrite(path, original)
    change_manifest { |m| m["artifacts"][0]["sha256"] = Digest::SHA256.file(artifact).hexdigest }
    assert_raises(GemRelease::Error) { @release.verify(tag: @tag, commit: @commit) }

    {autorequire: "injected", rdoc_options: ["--title", "injected"],
      extra_rdoc_files: ["lib/version.rb"], test_files: ["lib/version.rb"],
      specification_version: 3}.each do |field, value|
      File.binwrite(artifact, original_archive)
      spec = Gem::Package.new(artifact).spec
      spec.public_send("#{field}=", value)
      capture_io do
        Dir.chdir(File.join(@root, "gems/libtmux")) { Gem::Package.build(spec, true, false, artifact) }
      end
      assert Gem::Package.new(artifact).verify
      change_manifest { |m| m["artifacts"][0]["sha256"] = Digest::SHA256.file(artifact).hexdigest }
      error = assert_raises(GemRelease::Error, field.to_s) { @release.verify(tag: @tag, commit: @commit) }
      assert_match(/specification differs/, error.message)
    end
  end

  def test_yanked_later_version_prevents_every_upload_through_real_registry_adapter
    prepare
    responses = NAMES.each_with_object({}) do |name, result|
      result["/api/v2/rubygems/#{name}/versions/#{VERSION}.json?platform=ruby"] = ["404", "This version could not be found."]
      result["/api/v1/downloads/#{name}-#{VERSION}.json"] = ["404", "This rubygem could not be found."]
    end
    responses["/api/v1/downloads/libtmux-workspace-#{VERSION}.json"] = ["200", '{"total_downloads":0,"version_downloads":0}']
    pushes = []
    with_http(responses) do |registry|
      registry.define_singleton_method(:push) do |path, env:|
        pushes << path
        raise GemRelease::Error, "upload reached before preflight"
      end
      release = GemRelease.new(@root, registry: registry)
      error = assert_raises(GemRelease::Error) { release.publish(tag: @tag, commit: @commit, env: @env) }
      assert_empty pushes
      assert_match(/yanked|unavailable/, error.message)
    end
  end

  def test_later_existing_digest_mismatch_prevents_every_upload
    prepare
    @registry.versions["libtmux-workspace"] = "f" * 64
    assert_raises(GemRelease::Error) { publish }
    assert_empty @registry.pushes
    assert_equal NAMES, @registry.lookups.map(&:first)
  end

  def test_partial_upload_resumes_in_order_and_preserves_artifacts
    prepare
    before = retained_bytes
    @registry.fail_name = "libtmux-mcp"
    assert_raises(GemRelease::Error) { publish }
    assert_equal %w[libtmux libtmux-async], @registry.pushes
    assert_equal before, retained_bytes
    @registry.fail_name = nil
    publish
    assert_equal NAMES, @registry.pushes
    assert_equal before, retained_bytes
    @registry.lookups.clear
    publish
    assert_equal NAMES, @registry.pushes
    assert_equal NAMES, @registry.lookups.map(&:first)
  end

  def test_publish_rejects_untrusted_context_before_registry_access
    prepare
    @env.each_key do |key|
      assert_raises(GemRelease::Error) { publish(env: @env.merge(key => "wrong")) }
    end
    assert_empty @registry.lookups
    assert_empty @registry.pushes
  end

  def test_upload_without_registry_confirmation_is_retryable_failure
    prepare
    @registry.unconfirmed = true
    error = assert_raises(GemRelease::Error) { publish }
    assert_match(/retry/i, error.message)
    assert_equal ["libtmux"], @registry.pushes
  end

  def test_registry_lookup_failure_and_invalid_digest_prevent_all_uploads
    prepare
    @registry.lookup_error = "libtmux-workspace"
    assert_raises(GemRelease::Error) { publish }
    assert_empty @registry.pushes
    @registry.lookup_error = nil
    @registry.versions["libtmux-workspace"] = "invalid"
    assert_raises(GemRelease::Error) { publish }
    assert_empty @registry.pushes
  end

  def test_ignored_source_files_cannot_be_bound_to_a_commit
    git("rm", "--cached", "gems/libtmux/lib/version.rb")
    File.write(File.join(@root, ".gitignore"), "/pkg/\n/gems/libtmux/lib/version.rb\n")
    commit_changes
    assert_raises(GemRelease::Error) { prepare }
  end

  def test_source_versions_reload_after_an_external_bump
    prepare
    FileUtils.mv(release_dir, File.join(@root, "pkg/retained"))
    Dir[File.join(@root, "gems/**/*")].select { |path| File.file?(path) }.each do |path|
      File.write(path, File.read(path).gsub(VERSION, "0.1.0.alpha.2"))
    end
    commit_changes
    @tag = "v0.1.0.alpha.2"
    assert_equal "0.1.0.alpha.2", prepare.fetch("version")
  end

  private

  def constant(name) = name.split("-").map(&:capitalize).join
  def release_dir = File.join(@root, "pkg/release")
  def artifact = File.join(release_dir, "libtmux-#{VERSION}.gem")
  def retained_bytes = Dir.children(release_dir).to_h { |name| [name, File.binread(File.join(release_dir, name))] }
  def publish(env: @env) = @release.publish(tag: @tag, commit: @commit, env: env)

  def prepare
    result = nil
    capture_io { result = @release.prepare(tag: @tag, commit: @commit) }
    result
  end

  def change_manifest
    path = File.join(release_dir, "release.json")
    manifest = JSON.parse(File.read(path))
    yield manifest
    File.write(path, JSON.generate(manifest))
  end

  def commit_changes
    git("add", ".")
    git("-c", "user.name=Release Test", "-c", "user.email=release@example.invalid", "commit", "-qm", "change")
    @commit = git("rev-parse", "HEAD").strip
  end

  def git(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @root)
    raise output unless status.success?
    output
  end
end

class ReleaseRegistryTest < Minitest::Test
  include ReleaseHTTP

  VERSION_PATH = "/api/v2/rubygems/libtmux/versions/0.1.0.alpha.1.json?platform=ruby"
  DOWNLOADS_PATH = "/api/v1/downloads/libtmux-0.1.0.alpha.1.json"

  def test_push_options_are_accepted_by_the_installed_rubygems_cli
    registry = GemRelease.const_get(:RubyGemsRegistry).new
    assert_nil registry.push("--help", env: {"GEM_HOST_API_KEY" => "unused-test-key"})
  end

  def test_push_failure_preserves_cli_diagnostics_without_the_credential
    registry = GemRelease.const_get(:RubyGemsRegistry).new
    key = "private-test-credential"
    Dir.mktmpdir("libtmux-ruby-upload-") do |directory|
      error = assert_raises(GemRelease::Error) do
        registry.push(File.join(directory, "missing-#{key}.gem"), env: {"GEM_HOST_API_KEY" => key})
      end
      assert_includes error.message, "missing-[REDACTED].gem"
      refute_includes error.message, key
    end
  end

  def test_absence_requires_yanked_aware_lookup_and_errors_fail_closed
    with_http(VERSION_PATH => ["404", "This version could not be found."],
      DOWNLOADS_PATH => ["404", "This rubygem could not be found."]) do |registry|
      assert_nil registry.version_sha("libtmux", "0.1.0.alpha.1")
    end
    %w[301 401 403 429 500 503].each do |code|
      [VERSION_PATH, DOWNLOADS_PATH].each do |path|
        responses = {VERSION_PATH => ["404", "This version could not be found."], path => [code, "failure"]}
        with_http(responses) do |registry|
          assert_raises(GemRelease::Error, "#{path}: #{code}") { registry.version_sha("libtmux", "0.1.0.alpha.1") }
        end
      end
    end
  end

  def test_existing_version_requires_valid_identity_and_digest
    valid = {"name" => "libtmux", "version" => "0.1.0.alpha.1", "platform" => "ruby", "yanked" => false, "sha" => "a" * 64}
    with_http(VERSION_PATH => ["200", JSON.generate(valid)]) do |registry|
      assert_equal "a" * 64, registry.version_sha("libtmux", "0.1.0.alpha.1")
    end
    invalid = ["{", "[]", JSON.generate(valid.merge("name" => "other")),
      JSON.generate(valid.merge("version" => "0.1.0.alpha.2")), JSON.generate(valid.merge("platform" => "java")),
      JSON.generate(valid.merge("yanked" => true)), JSON.generate(valid.merge("sha" => "invalid"))]
    invalid.each do |body|
      with_http(VERSION_PATH => ["200", body]) do |registry|
        assert_raises(GemRelease::Error) { registry.version_sha("libtmux", "0.1.0.alpha.1") }
      end
    end
  end
end
