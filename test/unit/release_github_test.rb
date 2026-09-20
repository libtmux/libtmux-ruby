# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"
load File.expand_path("../../scripts/release-github", __dir__)

class GitHubReleaseTest < Minitest::Test
  TAG = "v0.1.0.alpha.1"
  COMMIT = "a" * 40
  Status = Struct.new(:success?)

  def setup
    @root = File.realpath(Dir.mktmpdir("libtmux-ruby-github-release-"))
    @directory = File.join(@root, "pkg/release")
    FileUtils.mkdir_p(@directory)
    artifacts = %w[libtmux libtmux-async libtmux-mcp libtmux-workspace].map do |name|
      filename = "#{name}-0.1.0.alpha.1.gem"
      File.write(File.join(@directory, filename), name)
      {"filename" => filename, "sha256" => Digest::SHA256.hexdigest(name)}
    end
    @manifest = {"tag" => TAG, "commit" => COMMIT, "artifacts" => artifacts}
    File.write(File.join(@directory, "release.json"), JSON.generate(@manifest))
    @expected = Dir.children(@directory).sort.map { |name| asset(name) }
    @remote = {"id" => 42, "tag_name" => TAG, "prerelease" => true, "draft" => false}
    @assets = @expected.map(&:dup)
    @commit = COMMIT
    @calls = []
    @writes = []
    @verifications = []
    verifier = Object.new
    owner = self
    verifier.define_singleton_method(:verify) { |**options| owner.verify_source(options) }
    @publisher = GitHubRelease.new(@root, release: verifier, command: method(:command))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_complete_retry_verifies_source_tag_and_all_assets_without_writes
    assert_equal @manifest, publish
    assert_equal [{tag: TAG, commit: COMMIT}], @verifications
    assert_empty @writes
    assert @calls.any? { |args| args.include?("--paginate") && args.include?("--slurp") }
  end

  def test_partial_retry_uploads_only_missing_assets_and_confirms_them
    @assets = @assets.reject { |entry| entry["name"] == "release.json" }
    assert_equal @manifest, publish
    assert_equal [["upload", ["release.json"]]], @writes
    assert_equal @expected, @assets.sort_by { |entry| entry.fetch("name") }
    publish
    assert_equal 1, @writes.length
  end

  def test_conflicts_are_checked_before_any_missing_asset_is_uploaded
    conflicts = [nil, "sha256:#{'f' * 64}", "sha512:#{'a' * 64}"]
    conflicts.each do |digest|
      @assets = @expected.drop(1).map(&:dup)
      @assets.last["digest"] = digest
      error = assert_raises(GitHubRelease::Error) { publish }
      assert_match(/asset.*SHA-256/, error.message)
      assert_empty @writes
    end
    ["draft", "prerelease", "tag_name"].each do |key|
      original = @remote[key]
      @remote[key] = key == "tag_name" ? "vwrong" : !original
      assert_raises(GitHubRelease::Error) { publish }
      assert_empty @writes
      @remote[key] = original
    end
    [@expected + [@expected.first.dup], @expected + [asset("extra")]].each do |assets|
      @assets = assets
      assert_raises(GitHubRelease::Error) { publish }
      assert_empty @writes
    end
  end

  def test_creation_requires_404_and_checks_all_uploaded_assets
    @remote = nil
    @assets = []
    assert_equal @manifest, publish
    assert_equal [["create", @expected.map { |entry| entry.fetch("name") }.sort]], @writes
    create = @calls.find { |args| args[1, 2] == %w[release create] }
    %w[--verify-tag --prerelease --latest=false].each { |flag| assert_includes create, flag }
    refute_includes create, "--clobber"
  end

  def test_tag_404_checks_later_pages_for_a_draft_before_attempting_creation
    @remote["draft"] = true
    @lookup_failure = 404
    @release_pages = [[{"tag_name" => "v0.0.0"}], [@remote]]
    error = assert_raises(GitHubRelease::Error) { publish }
    refute @calls.any? { |args| args[1] == "release" }, "existing draft reached release creation"
    assert_match(/draft/, error.message)
    listing = @calls.find { |args| args[2].include?("/releases?") }
    assert_includes listing, "--paginate"
    assert_includes listing, "--slurp"
  end

  def test_tag_404_with_failed_or_invalid_listing_never_attempts_creation
    [:failure, {}, [], [nil], [[{}]]].each do |pages|
      @remote = nil
      @assets = []
      @calls.clear
      @release_pages = pages
      assert_raises(GitHubRelease::Error) { publish }
      refute @calls.any? { |args| args[1] == "release" }, "invalid listing reached release creation"
    end
  end

  def test_api_failures_never_turn_into_release_creation
    [401, 403, 429, 500, nil].each do |code|
      @lookup_failure = code || :connection
      error = assert_raises(GitHubRelease::Error) { publish }
      assert_match(code ? /HTTP #{code}/ : /connection failed/, error.message)
      assert_empty @writes
    end
  end

  def test_invalid_api_data_or_unfinished_assets_stop_before_any_upload
    @assets.last["state"] = "starter"
    assert_raises(GitHubRelease::Error) { publish }
    @assets = @expected.map(&:dup)
    @invalid_lookup = true
    assert_raises(GitHubRelease::Error) { publish }
    @invalid_lookup = false
    [{}, []].each do |pages|
      @invalid_assets = pages
      assert_raises(GitHubRelease::Error) { publish }
    end
    assert_empty @writes
  end

  def test_failed_partial_upload_can_resume_without_replacing_the_first_file
    @assets = []
    @fail_upload = true
    error = assert_raises(GitHubRelease::Error) { publish }
    assert_match(/fixture upload interrupted/, error.message)
    assert_equal 1, @assets.length
    retained = @assets.first.dup
    @fail_upload = false
    assert_equal @manifest, publish
    assert_includes @assets, retained
    refute_includes @writes.last.last, retained.fetch("name")
  end

  def test_tag_and_retained_source_must_match_before_any_write
    @commit = "b" * 40
    @branch_commit = COMMIT
    assert_raises(GitHubRelease::Error) { publish }
    assert_empty @writes
    assert_equal 1, @calls.length
    @calls.clear
    @source_error = true
    assert_raises(GemRelease::Error) { publish }
    assert_empty @calls
  end

  def test_successful_upload_still_requires_complete_matching_confirmation
    @assets = []
    @after_upload = -> { @assets.last["digest"] = "sha256:#{'f' * 64}" }
    assert_raises(GitHubRelease::Error) { publish }
    assert_equal 1, @writes.length
    @assets = []
    @after_upload = -> { @assets.pop }
    error = assert_raises(GitHubRelease::Error) { publish }
    assert_match(/incomplete/, error.message)
  end

  def verify_source(options)
    @verifications << options
    raise GemRelease::Error, "retained source differs" if @source_error
    @manifest
  end

  private

  def publish = @publisher.publish(tag: TAG, commit: COMMIT)

  def asset(name)
    path = File.join(@directory, name)
    {"name" => name, "state" => "uploaded", "digest" => "sha256:#{File.file?(path) ? Digest::SHA256.file(path).hexdigest : 'f' * 64}"}
  end

  def response(body, success: true, errors: "") = [JSON.generate(body), errors, Status.new(success)]

  def command(*args, chdir:)
    assert_equal @root, chdir
    assert_equal "gh", args.first
    @calls << args
    if args[1] == "api"
      assert_equal "github.com", args[args.index("--hostname") + 1]
      path = args[2]
      if path.include?("/commits/")
        sha = path.end_with?("/commits/#{TAG}") ? (@branch_commit || @commit) : @commit
        response({"sha" => sha})
      elsif path.include?("/releases/tags/")
        return ["", "connection failed", Status.new(false)] if @lookup_failure == :connection
        code = @lookup_failure || (@remote ? 200 : 404)
        body = code == 200 ? @remote : {"message" => "Not Found", "status" => "404"}
        json = @invalid_lookup ? "{" : JSON.generate(body)
        ["HTTP/2.0 #{code} Test\r\nContent-Type: application/json\r\n\r\n#{json}", "", Status.new(code == 200)]
      elsif path.include?("/releases?")
        return response({}, success: false, errors: "release list unavailable") if @release_pages == :failure
        response(@release_pages || [[]])
      elsif path.include?("/assets?")
        response(@invalid_assets || [@assets.first(2), @assets.drop(2)])
      else
        flunk "unexpected API path #{path}"
      end
    else
      assert_equal "github.com/libtmux/libtmux-ruby", args[args.index("--repo") + 1]
      refute_includes args, "--clobber"
      operation = args[2]
      return response({"message" => "release already exists"}, success: false) if operation == "create" && @remote
      @remote ||= {"id" => 42, "tag_name" => TAG, "prerelease" => true, "draft" => false}
      paths = args[4...args.index("--repo")]
      names = paths.map { |path| File.basename(path) }
      @writes << [operation, names.sort]
      if @fail_upload
        @assets << asset(names.first)
        return response({"message" => "upload interrupted"}, success: false, errors: "fixture upload interrupted\n")
      end
      @assets += names.map { |name| asset(name) }
      @after_upload&.call
      response({"ok" => true})
    end
  end
end
