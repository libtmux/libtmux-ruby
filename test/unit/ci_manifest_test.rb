# frozen_string_literal: true

require_relative "../test_helper"

load File.expand_path("../../scripts/ci_manifest.rb", __dir__)

# The manifest is the one list of what CI covers. Each rule below has a case
# that breaks it, so a guard that stops guarding fails here.
class CIManifestTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  READMES = %w[README.md gems/libtmux/README.md gems/libtmux-async/README.md
    gems/libtmux-mcp/README.md gems/libtmux-workspace/README.md].freeze

  def manifest
    @manifest ||= CIManifest.load
  end

  def broken
    copy = Marshal.load(Marshal.dump(manifest))
    yield copy
    CIManifest.problems(copy)
  end

  def test_the_manifest_is_consistent
    assert_equal [], CIManifest.problems(manifest)
    assert_equal %w[3.3a 3.8], CIManifest.supported(manifest).values_at(0, -1)
  end

  def test_versions_order_by_release_and_patch_letter
    ordered = %w[3.3a 3.4 3.5a 3.6 3.7c 3.8]
    assert ordered.each_cons(2).all? { |older, newer| CIManifest.before?(older, newer) }
    assert CIManifest.before?("3.3", "3.3a")
    assert CIManifest.before?("3.8", "3.9")
    refute CIManifest.before?("3.8", "3.8")
    assert_raises(ArgumentError) { CIManifest.version_key("next-3.9") }
  end

  def test_a_digest_is_found_for_a_release_and_missing_for_anything_else
    assert_match CIManifest::DIGEST, CIManifest.sha256(manifest, "3.8")
    assert_match CIManifest::DIGEST, CIManifest.sha256(manifest, "3.0a")
    assert_raises(KeyError) { CIManifest.sha256(manifest, "master") }
  end

  def test_each_rule_reports_its_break
    {
      "the manifest lists no supported release" => ->(copy) { copy["supported"] = [] },
      "the manifest lists no Ruby" => ->(copy) { copy["rubies"] = [] },
      "a release is listed twice" => ->(copy) { copy["unsupported"] << copy["supported"].first },
      "supported releases must run oldest first" => ->(copy) { copy["supported"].reverse! },
      "a refused release is not older than the oldest supported one" => ->(copy) { copy["unsupported"] << {"tmux" => "3.9", "sha256" => "a" * 64, "check" => "refused"} },
      "release 3.8 has no SHA-256" => ->(copy) { copy["supported"].last["sha256"] = "3.8" },
      "refused release 3.3 has no known check" => ->(copy) { copy["unsupported"].last["check"] = "skip" },
      "development build next-3.9 has no full commit" => ->(copy) { copy["development"].first["commit"] = "main" },
      "the manifest lists a system other than linux" => ->(copy) { copy["systems"] << "macos" }
    }.each do |message, mutation|
      assert_includes broken(&mutation), message
    end
  end

  def test_a_release_that_is_not_a_tmux_version_is_reported
    assert_includes broken { |copy| copy["supported"].first["tmux"] = "master" }, "master is not a tmux release"
  end

  # What a README says about the tested range, against the manifest.
  def range_problems(path, text)
    supported = CIManifest.supported(manifest)
    rubies = CIManifest.rubies(manifest).map { |version| version[/\A\d+\.\d+/] }
    text = text.gsub(/\s+/, " ")
    found = []
    found << "#{path} states another tmux range" unless
      text.match(/tmux (\d\.\d[a-z]?) through (\d\.\d[a-z]?)/)&.captures == [supported.first, supported.last]
    found << "#{path} states other Rubies" unless text.include?("Ruby #{rubies[0..-2].join(', ')} and #{rubies.last}")
    found
  end

  def test_the_readmes_state_the_range_the_manifest_lists
    READMES.each do |path|
      assert_equal [], range_problems(path, File.read(File.join(ROOT, path)))
    end
  end

  def test_a_readme_that_states_another_range_is_reported
    text = File.read(File.join(ROOT, "README.md"))
    assert_equal ["README.md states another tmux range"], range_problems("README.md", text.sub("through 3.8", "through 3.7c"))
    assert_equal ["README.md states other Rubies"], range_problems("README.md", text.sub("Ruby 3.3, 3.4 and 4.0", "Ruby 3.3 and 4.0"))
  end
end
