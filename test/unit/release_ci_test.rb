# frozen_string_literal: true

require_relative "../test_helper"
load File.expand_path("../../scripts/release-ci", __dir__)

class ReleaseCITest < Minitest::Test
  COMMIT = "a" * 40

  def test_requires_completed_compatibility_run_for_exact_master_commit
    run = {"id" => 42, "head_sha" => COMMIT, "head_branch" => "master",
      "event" => "push", "path" => ".github/workflows/compatibility.yml",
      "status" => "completed", "conclusion" => "success"}
    jobs = {"jobs" => [{"name" => "All 36 required cells", "conclusion" => "success"}]}
    queries = []
    client = lambda do |path|
      queries << path
      path.include?("/jobs?") ? jobs : {"workflow_runs" => [run]}
    end
    assert_equal 42, ReleaseCI.new(client: client).check(COMMIT)
    assert_includes queries.first, "head_sha=#{COMMIT}"

    {"head_sha" => "b" * 40, "head_branch" => "package", "event" => "pull_request",
      "path" => ".github/workflows/other.yml", "status" => "in_progress",
      "conclusion" => "failure"}.each do |key, value|
      invalid = run.merge(key => value)
      error = assert_raises(ReleaseCI::Error) do
        ReleaseCI.new(client: ->(_) { {"workflow_runs" => [invalid]} }).check(COMMIT)
      end
      assert_match(/compatibility/, error.message)
    end
    %w[failure skipped cancelled].each do |conclusion|
      jobs["jobs"].first["conclusion"] = conclusion
      assert_raises(ReleaseCI::Error) { ReleaseCI.new(client: client).check(COMMIT) }
    end
    jobs["jobs"] = []
    assert_raises(ReleaseCI::Error) { ReleaseCI.new(client: client).check(COMMIT) }
  end

  def test_rejects_invalid_commit_without_network_access
    client = ->(_) { flunk "invalid commit reached GitHub" }
    assert_raises(ReleaseCI::Error) { ReleaseCI.new(client: client).check("HEAD") }
  end
end
