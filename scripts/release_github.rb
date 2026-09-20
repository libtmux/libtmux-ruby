# frozen_string_literal: true

require "digest"
require "json"
require "open3"
load File.expand_path("release.rb", __dir__) unless defined?(GemRelease)

class GitHubRelease
  class Error < StandardError; end

  REPOSITORY = "libtmux/libtmux-ruby"

  def initialize(root, release: GemRelease.new(root), command: Open3.method(:capture3))
    @root = File.realpath(root)
    @directory = File.join(@root, "pkg/release")
    @release = release
    @command = command
  end

  def publish(tag:, commit:)
    manifest = @release.verify(tag: tag, commit: commit)
    expected = manifest.fetch("artifacts").to_h { |entry| [entry.fetch("filename"), "sha256:#{entry.fetch('sha256')}"] }
    expected["release.json"] = "sha256:#{Digest::SHA256.file(File.join(@directory, 'release.json')).hexdigest}"
    verify_tag(tag, commit)
    release = lookup(tag)
    if release
      missing = verify_assets(release, tag, expected)
      unless missing.empty?
        run("release", "upload", tag, *missing.map { |name| File.join(@directory, name) }, "--repo", "github.com/#{REPOSITORY}")
      end
    else
      run("release", "create", tag, *expected.keys.map { |name| File.join(@directory, name) },
        "--repo", "github.com/#{REPOSITORY}", "--verify-tag", "--prerelease", "--latest=false",
        "--title", "libtmux #{tag}", "--notes-file", File.join(@root, "CHANGELOG.md"))
    end
    verify_tag(tag, commit)
    missing = verify_assets(lookup(tag), tag, expected)
    raise Error, "GitHub release assets are incomplete; retry with retained artifacts" unless missing.empty?
    manifest
  end

  private

  def verify_tag(tag, commit)
    data = json_api("commits/refs/tags/#{tag}")
    raise Error, "GitHub release tag commit differs from retained source" unless data.is_a?(Hash) && data["sha"] == commit
  end

  def lookup(tag)
    output, errors, status = @command.call("gh", "api", "repos/#{REPOSITORY}/releases/tags/#{tag}",
      "--hostname", "github.com", "--include", chdir: @root)
    headers, body = output.split(/\r?\n\r?\n/, 2)
    code = headers&.match(/\AHTTP\/\S+ (\d{3})(?: |\r?\n|\z)/)&.[](1)
    if code == "404" && !status.success?
      # The tag endpoint omits drafts; push-authorized release listings include them.
      pages = json_api("releases?per_page=100", "--paginate", "--slurp")
      valid = pages.is_a?(Array) && !pages.empty? && pages.all? { |page| page.is_a?(Array) } &&
        pages.flatten(1).all? { |entry| entry.is_a?(Hash) && entry["tag_name"].is_a?(String) }
      raise Error, "GitHub release listing is invalid; inspect drafts before retry" unless valid
      if pages.flatten(1).any? { |entry| entry["tag_name"] == tag }
        raise Error, "GitHub release already exists in the listing; inspect drafts before retry"
      end
      return nil
    end
    fail_command("release lookup#{" (HTTP #{code})" if code}", errors) unless code == "200" && status.success?
    JSON.parse(body)
  rescue JSON::ParserError, TypeError
    raise Error, "GitHub release lookup returned invalid JSON"
  end

  def verify_assets(release, tag, expected)
    valid = release.is_a?(Hash) && release["tag_name"] == tag && release["prerelease"] == true &&
      release["draft"] == false && release["id"].is_a?(Integer) && release["id"].positive?
    raise Error, "GitHub release identity differs; retain artifacts and investigate" unless valid
    pages = json_api("releases/#{release.fetch('id')}/assets?per_page=100", "--paginate", "--slurp")
    raise Error, "GitHub release returned invalid asset pages" unless pages.is_a?(Array) && !pages.empty? && pages.all? { |page| page.is_a?(Array) }
    assets = pages.flatten(1)
    names = []
    assets.each do |asset|
      valid = asset.is_a?(Hash) && expected.key?(asset["name"]) && asset["state"] == "uploaded" &&
        asset["digest"] == expected[asset["name"]] && !names.include?(asset["name"])
      raise Error, "GitHub release asset name or SHA-256 differs; never replace assets" unless valid
      names << asset.fetch("name")
    end
    expected.keys - names
  end

  def json_api(path, *arguments)
    JSON.parse(run("api", "repos/#{REPOSITORY}/#{path}", "--hostname", "github.com", *arguments))
  rescue JSON::ParserError
    raise Error, "GitHub release API returned invalid JSON"
  end

  def run(*arguments)
    output, errors, status = @command.call("gh", *arguments, chdir: @root)
    operation = arguments.first == "release" ? arguments[1] : "API request"
    fail_command(operation, errors) unless status.success?
    output
  end

  def fail_command(operation, errors)
    detail = errors.lines.first.to_s.strip
    raise Error, "GitHub #{operation} failed#{": #{detail}" unless detail.empty?}; retry with retained artifacts"
  end

end
