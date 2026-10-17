# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"

# A matrix entry that builds a tmux release but runs no version-check test
# would pass its job, so the workflow must fail on one.
class CompatibilityWorkflowTest < Minitest::Test
  WORKFLOW = YAML.safe_load_file(File.expand_path("../../.github/workflows/compatibility.yml", __dir__), aliases: false)

  def test_every_unsupported_release_has_a_version_check_arm_and_an_unknown_one_fails
    job = WORKFLOW.fetch("jobs").fetch("unsupported")
    script = job.fetch("steps").map { |step| step["run"] }.compact.find { |run| run.include?("case \"$TMUX_VERSION\"") }
    refute_nil script, "the unsupported job must select its test by release"
    arms = script.scan(/^\s*([\w.|*)]+)\)\s*$/).flatten.flat_map { |arm| arm.split("|") }
    job.fetch("strategy").fetch("matrix").fetch("tmux").each { |release| assert_includes arms, release }
    assert_match(/^\s*\*\)\n\s*echo [^\n]*>&2\n\s*exit 1 ;;/, script)
  end

  def test_supported_cells_name_their_lane
    assert_equal "supported", WORKFLOW.fetch("jobs").fetch("cell").fetch("env").fetch("LIBTMUX_VERSION_CHECK_EXPECT")
  end
end
