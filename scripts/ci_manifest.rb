# frozen_string_literal: true

require "json"

# The one list of what CI covers: the Rubies, the tmux releases the library
# supports (oldest first), the releases it refuses and the development build.
# The workflow, scripts/matrix and scripts/ci-plan read it; nothing else
# writes a version down, and the tests tie the documents to it.
module CIManifest
  PATH = File.expand_path("ci-matrix.json", __dir__)
  CHECKS = %w[old_daemon refused].freeze
  DIGEST = /\A[0-9a-f]{64}\z/
  COMMIT = /\A[0-9a-f]{40}\z/

  def self.load(path = PATH)
    JSON.parse(File.read(path))
  end

  def self.rubies(manifest)
    manifest.fetch("rubies")
  end

  def self.supported(manifest)
    manifest.fetch("supported").map { |entry| entry.fetch("tmux") }
  end

  def self.unsupported(manifest)
    manifest.fetch("unsupported").map { |entry| entry.fetch("tmux") }
  end

  def self.sha256(manifest, tmux)
    entry = (manifest.fetch("supported") + manifest.fetch("unsupported")).find { |item| item.fetch("tmux") == tmux }
    raise KeyError, "tmux #{tmux} is not a release in the manifest" unless entry

    entry.fetch("sha256")
  end

  # Orders 3.3a < 3.4 < 3.5a, so the first and last supported entries are the
  # oldest and newest release.
  def self.version_key(version)
    major, minor, patch = version.match(/\A(\d+)\.(\d+)([a-z]?)\z/)&.captures
    raise ArgumentError, "#{version} is not a tmux release" unless major

    [major.to_i, minor.to_i, patch]
  end

  def self.before?(older, newer)
    (version_key(older) <=> version_key(newer)).negative?
  end

  def self.problems(manifest)
    found = []
    supported = supported(manifest)
    unsupported = unsupported(manifest)
    found << "the manifest lists no supported release" if supported.empty?
    found << "the manifest lists no Ruby" if rubies(manifest).empty?
    found << "a release is listed twice" unless (supported + unsupported).uniq.length == (supported + unsupported).length
    begin
      found << "supported releases must run oldest first" unless supported.each_cons(2).all? { |a, b| before?(a, b) }
      found << "a refused release is not older than the oldest supported one" unless
        supported.empty? || unsupported.all? { |version| before?(version, supported.first) }
    rescue ArgumentError => error
      found << error.message
    end
    (manifest.fetch("supported") + manifest.fetch("unsupported")).each do |entry|
      found << "release #{entry['tmux']} has no SHA-256" unless DIGEST.match?(entry["sha256"].to_s)
    end
    manifest.fetch("unsupported").each do |entry|
      found << "refused release #{entry['tmux']} has no known check" unless CHECKS.include?(entry["check"])
    end
    manifest.fetch("development").each do |entry|
      found << "development build #{entry['tmux']} has no full commit" unless COMMIT.match?(entry["commit"].to_s)
    end
    found << "the manifest lists a system other than linux" unless manifest.fetch("systems") == ["linux"]
    found
  end
end
