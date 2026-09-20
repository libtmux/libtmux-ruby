# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "securerandom"
require "stringio"
require "tmpdir"

# Maintainer tooling; retained bytes are the unit of publication and retries.
class GemRelease
  class Error < StandardError; end

  NAMES = %w[libtmux libtmux-async libtmux-mcp libtmux-workspace].freeze
  SIBLINGS = [[], ["libtmux"], %w[libtmux libtmux-async], ["libtmux"]].freeze
  # RubyGems derives the package date/version and removes the private signing key.
  BUILD_FIELDS = %w[date rubygems_version signing_key].freeze
  SHA256 = /\A[0-9a-f]{64}\z/

  def initialize(root, registry: nil)
    @root = File.realpath(root)
    @directory = File.join(@root, "pkg/release")
    @registry = registry
  end

  def prepare(tag:, commit:)
    specs = source_specs(tag, commit)
    FileUtils.mkdir_p(File.dirname(@directory))
    File.open(File.join(@root, "pkg/.release.lock"), "w") do |lock|
      lock.flock(File::LOCK_EX)
      return verify(tag: tag, commit: commit) if File.exist?(@directory) || File.symlink?(@directory)

      temporary = Dir.mktmpdir(".release-", File.dirname(@directory))
      begin
        artifacts = specs.map do |spec|
          filename = "#{spec.full_name}.gem"
          destination = File.join(temporary, filename)
          Dir.chdir(File.join(@root, "gems", spec.name)) do
            Gem::Package.build(spec, false, true, destination)
          end
          {"name" => spec.name, "version" => spec.version.to_s,
            "filename" => filename, "sha256" => Digest::SHA256.file(destination).hexdigest}
        end
        manifest = {"format" => 1, "tag" => tag, "version" => specs.first.version.to_s,
          "commit" => commit, "artifacts" => artifacts}
        File.write(File.join(temporary, "release.json"), JSON.pretty_generate(manifest) + "\n")
        verify_directory(temporary, manifest, specs, tag, commit)
        check_checkout(commit)
        File.rename(temporary, @directory)
        manifest
      ensure
        FileUtils.remove_entry(temporary) if File.exist?(temporary)
      end
    end
  end

  def verify(tag:, commit:)
    specs = source_specs(tag, commit)
    fail_release("release directory is missing or symlinked") unless File.directory?(@directory) && !File.symlink?(@directory)
    path = File.join(@directory, "release.json")
    fail_release("release manifest is missing or symlinked") unless File.file?(path) && !File.symlink?(path)
    manifest = JSON.parse(File.read(path))
    verify_directory(@directory, manifest, specs, tag, commit)
    manifest
  rescue JSON::ParserError, SystemCallError, Gem::Package::Error, Zlib::Error => error
    raise Error, "release verification failed: #{error.class}; retain artifacts and investigate"
  end

  def publish(tag:, commit:, env: ENV)
    manifest = verify(tag: tag, commit: commit)
    expected = {"GITHUB_ACTIONS" => "true", "GITHUB_EVENT_NAME" => "push",
      "GITHUB_REPOSITORY" => "libtmux/libtmux-ruby", "GITHUB_REF" => "refs/tags/#{tag}",
      "GITHUB_SHA" => commit,
      "GITHUB_WORKFLOW_REF" => "libtmux/libtmux-ruby/.github/workflows/release.yml@refs/tags/#{tag}"}
    expected.each do |key, value|
      fail_release("publication requires the release tag workflow: #{key} differs") unless env[key] == value
    end
    registry = @registry || RubyGemsRegistry.new
    artifacts = manifest.fetch("artifacts")
    existing = artifacts.map { |entry| registry_sha(registry, entry) }
    artifacts.zip(existing).each do |entry, sha|
      fail_release("registry digest differs for #{entry.fetch('name')}; never replace a published version") if sha && sha != entry.fetch("sha256")
    end
    artifacts.zip(existing).each do |entry, sha|
      next if sha

      registry.push(File.join(@directory, entry.fetch("filename")), env: env)
      actual = registry_sha(registry, entry)
      fail_release("registry has not confirmed #{entry.fetch('name')}; retry with retained artifacts") unless actual
      fail_release("registry digest differs after publishing #{entry.fetch('name')}; investigate before retry") unless actual == entry.fetch("sha256")
    end
    manifest
  end

  private

  def fail_release(message)
    raise Error, message
  end

  def git(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @root)
    fail_release("release source git check failed") unless status.success?
    output
  end

  def check_checkout(commit)
    fail_release("release commit must be the full current HEAD") unless commit.is_a?(String) && /\A[0-9a-f]{40,64}\z/.match?(commit) && git("rev-parse", "HEAD").strip == commit
    fail_release("release source must have no tracked or untracked changes") unless git("status", "--porcelain", "--untracked-files=all").empty?
  end

  def source_specs(tag, commit)
    fail_release("release tag must be vVERSION") unless tag.is_a?(String) && /\Av[0-9]+(?:\.[0-9A-Za-z]+)*\z/.match?(tag)
    version = tag.delete_prefix("v")
    fail_release("release tag must use the canonical gem version") unless Gem::Version.correct?(version) && Gem::Version.new(version).to_s == version
    check_checkout(commit)
    return @source_specs if @source_identity == [tag, commit]

    # A separate interpreter avoids require caches after another process bumps versions.
    code = <<~'RUBY'
      require "rubygems"
      require "json"
      specs = ARGV.map do |path|
        spec = Gem::Specification.load(path)
        abort "cannot load release gemspec" unless spec
        spec
      end
      STDOUT.write(JSON.generate(specs.map(&:to_yaml)))
    RUBY
    paths = NAMES.map { |name| File.join(@root, "gems", name, "#{name}.gemspec") }
    output, _errors, status = Open3.capture3(Gem.ruby, "-e", code, *paths, chdir: @root)
    fail_release("release gemspec loading failed") unless status.success?
    specs = JSON.parse(output).map { |yaml| Gem::Specification.from_yaml(yaml) }
    tracked = git("ls-files", "-z").split("\0")
    specs.each_with_index do |spec, index|
      fail_release("release gemspec must be tracked") unless tracked.include?("gems/#{NAMES[index]}/#{NAMES[index]}.gemspec")
      fail_release("release gem name, platform or version differs from tag") unless spec.name == NAMES[index] && spec.version.to_s == version && spec.platform == Gem::Platform::RUBY
      siblings = spec.dependencies.select { |dependency| NAMES.include?(dependency.name) }
      valid = siblings.map(&:name).sort == SIBLINGS[index].sort && siblings.all? do |dependency|
        dependency.type == :runtime && dependency.requirement.to_s == "= #{version}"
      end
      fail_release("release sibling dependencies must match the exact suite version") unless valid
      spec.files.each do |file|
        fail_release("release source file is unsafe, missing or untracked") unless safe_path?(file) &&
          tracked.include?("gems/#{spec.name}/#{file}") && regular_source?(spec.name, file)
      end
    end
    @source_identity = [tag, commit]
    @source_specs = specs
  end

  def safe_path?(path)
    path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.include?("\\") &&
      !path.include?("\0") && path.split("/", -1).none? { |part| ["", ".", ".."].include?(part) }
  end

  def regular_source?(name, path)
    directory = File.join(@root, "gems", name)
    full_path = File.join(directory, path)
    File.file?(full_path) && File.realpath(full_path) == full_path
  end

  def spec_identity(spec)
    normalized = spec.dup
    normalized.normalize
    coder = Psych::Coder.new(nil)
    normalized.encode_with(coder)
    Psych.dump(coder.map.reject { |field, _| BUILD_FIELDS.include?(field) })
  end

  def verify_directory(directory, manifest, specs, tag, commit)
    header = {"format" => 1, "tag" => tag, "version" => tag.delete_prefix("v"), "commit" => commit}
    valid = manifest.is_a?(Hash) && manifest.keys.sort == (header.keys + ["artifacts"]).sort &&
      header.all? { |key, value| manifest[key] == value } && manifest["artifacts"].is_a?(Array) &&
      manifest["artifacts"].length == specs.length
    fail_release("release manifest metadata differs from source") unless valid
    filenames = specs.map { |spec| "#{spec.full_name}.gem" }
    fail_release("release artifact set is incomplete or contains extra files") unless Dir.children(directory).sort == (filenames + ["release.json"]).sort
    specs.zip(manifest.fetch("artifacts"), filenames).each do |spec, entry, filename|
      valid = entry.is_a?(Hash) && entry.keys.sort == %w[filename name sha256 version] &&
        entry["filename"] == filename && entry["name"] == spec.name && entry["version"] == spec.version.to_s &&
        entry["sha256"].is_a?(String) && SHA256.match?(entry["sha256"])
      fail_release("release artifact metadata or filename differs from source") unless valid
      path = File.join(directory, filename)
      fail_release("release artifact is not a regular file") unless File.file?(path) && !File.symlink?(path)
      fail_release("release artifact digest differs: #{filename}") unless Digest::SHA256.file(path).hexdigest == entry["sha256"]
      package = Gem::Package.new(path)
      package.verify
      fail_release("release archive specification differs: #{filename}") unless spec_identity(package.spec) == spec_identity(spec)
      verify_contents(path, spec)
    end
  end

  def verify_contents(path, spec)
    contents = []
    File.open(path, "rb") do |input|
      Gem::Package::TarReader.new(input) do |archive|
        archive.each do |member|
          next unless member.full_name == "data.tar.gz"

          Zlib::GzipReader.wrap(StringIO.new(member.read)) do |gzip|
            Gem::Package::TarReader.new(gzip) do |data|
              data.each do |file|
                name = file.full_name
                fail_release("release archive contains an unsafe entry") unless file.file? && safe_path?(name) && spec.files.include?(name)
                source = File.join(@root, "gems", spec.name, name)
                fail_release("release archive content differs: #{spec.name}/#{name}") unless Digest::SHA256.hexdigest(file.read) == Digest::SHA256.file(source).hexdigest
                fail_release("release archive executable mode differs: #{name}") unless file.header.mode & 0o111 == File.stat(source).mode & 0o111
                contents << name
              end
            end
          end
        end
      end
    end
    fail_release("release archive file set differs: #{spec.name}") unless contents.sort == spec.files.sort
  end

  def registry_sha(registry, entry)
    sha = registry.version_sha(entry.fetch("name"), entry.fetch("version"))
    fail_release("registry returned an invalid digest; retry with retained artifacts") unless sha.nil? || (sha.is_a?(String) && SHA256.match?(sha))
    sha
  end

  class RubyGemsRegistry
    HOST = "https://rubygems.org"

    def version_sha(name, version)
      require "net/http"
      response = get("/api/v2/rubygems/#{name}/versions/#{version}.json?platform=ruby")
      if response.code == "404"
        # The downloads endpoint retains yanked versions; the v2 endpoint hides them.
        response = get("/api/v1/downloads/#{name}-#{version}.json")
        raise Error, "registry version is yanked or unavailable: #{name}; never replace a published version" unless response.code == "404"
        return nil
      end

      data = JSON.parse(response.body)
      valid = data.is_a?(Hash) && data["name"] == name && data["version"] == version &&
        data["platform"] == "ruby" && data["yanked"] == false &&
        data["sha"].is_a?(String) && SHA256.match?(data["sha"])
      raise Error, "registry returned invalid version metadata; retry with retained artifacts" unless valid
      data.fetch("sha")
    rescue JSON::ParserError, IOError, SystemCallError, SocketError, Timeout::Error,
      Net::HTTPBadResponse, OpenSSL::SSL::SSLError => error
      raise Error, "registry lookup failed (#{error.class}); retry with retained artifacts"
    end

    def push(path, env:)
      key = env["GEM_HOST_API_KEY"]
      raise Error, "publication requires the trusted publishing action credential" unless key.is_a?(String) && !key.strip.empty?

      output, errors, status = Open3.capture3({"GEM_HOST_API_KEY" => key}, Gem.ruby, "-S", "gem",
        "push", path, "--norc", "--host", HOST)
      unless status.success?
        detail = [output, errors].reject(&:empty?).join("\n").gsub(key, "[REDACTED]").byteslice(0, 4096).scrub.strip
        raise Error, "gem push failed: #{detail}; retry with retained artifacts"
      end
    end

    private

    def get(path)
      uri = URI("#{HOST}#{path}")
      # Fastly caches missing versions too; preflight must not mask a later push.
      uri.query = [uri.query, "release_check=#{SecureRandom.hex(16)}"].compact.join("&")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
        http.get(uri.request_uri)
      end
      raise Error, "registry lookup failed (HTTP #{response.code}); retry with retained artifacts" unless %w[200 404].include?(response.code)
      response
    end
  end
  private_constant :RubyGemsRegistry
end
