# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
load File.expand_path("../../scripts/release-ci", __dir__) unless defined?(ReleaseCI)

class ReleaseCITest < Minitest::Test
  COMMIT = "a" * 40

  def test_requires_completed_compatibility_run_for_exact_master_commit
    run = {"id" => 42, "head_sha" => COMMIT, "head_branch" => "master",
      "event" => "push", "path" => ".github/workflows/compatibility.yml",
      "status" => "completed", "conclusion" => "success"}
    jobs = {"jobs" => [{"name" => "All required cells", "conclusion" => "success"}]}
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

  # The restore step of a retried release run. The client answers from a table
  # of GitHub paths, so no network is used, and the downloader records the call.
  class Run
    REPOSITORY = "libtmux/libtmux-ruby"
    ID = "77"

    attr_reader :downloads, :queries

    def initialize(artifacts: [], jobs: [])
      @artifacts, @jobs = artifacts, jobs
      @downloads, @queries = [], []
    end

    def client
      lambda do |path|
        @queries << path
        case path
        when %r{/runs/#{ID}/artifacts\?} then {"artifacts" => @artifacts.map { |name| {"name" => name} }}
        when %r{/runs/#{ID}/jobs\?filter=all&per_page=100&page=(\d+)\z}
          page = Regexp.last_match(1).to_i
          {"jobs" => @jobs.slice((page - 1) * 100, 100) || []}
        else raise "unexpected request #{path}"
        end
      end
    end

    def restore(attempt, directory: "pkg/release")
      ReleaseCI.new(client: client, downloader: ->(*call) { @downloads << call })
        .restore(repository: REPOSITORY, run_id: ID, attempt: attempt, directory: directory)
    end
  end

  def publish_job(conclusion, job: ReleaseCI::PUBLISH_JOB, step: ReleaseCI::PUBLISH_STEP)
    {"name" => job, "steps" => [{"name" => "Set up job", "conclusion" => "success"}, {"name" => step, "conclusion" => conclusion}]}
  end

  def test_restore_downloads_the_retained_artifact_set
    run = Run.new(artifacts: ["other", "rubygems-release"])
    assert run.restore(2)
    assert_equal [["77", "rubygems-release", "pkg/release"]], run.downloads
    assert_equal ["repos/libtmux/libtmux-ruby/actions/runs/77/artifacts?per_page=100"], run.queries
  end

  def test_restore_prefers_the_artifact_even_after_publication_started
    run = Run.new(artifacts: ["rubygems-release"], jobs: [publish_job("failure")])
    assert run.restore(3)
    assert_equal 1, run.downloads.length
  end

  def test_the_first_attempt_without_an_artifact_builds_one
    run = Run.new(jobs: [publish_job("success")])
    refute run.restore(1)
    assert_empty run.downloads
    assert_equal 1, run.queries.length, "the first attempt must not read the jobs"
  end

  def test_a_retry_that_never_reached_the_upload_builds_one
    [[], [publish_job("skipped")], [publish_job("success", job: "Validate and retain artifacts")],
     [publish_job("success", step: "Verify the retained files before requesting credentials")]].each do |jobs|
      run = Run.new(jobs: jobs)
      refute run.restore(2), jobs.inspect
      assert_empty run.downloads
    end
  end

  def test_a_retry_that_started_the_upload_without_its_artifact_stops
    %w[success failure cancelled].push(nil).each do |conclusion|
      error = assert_raises(ReleaseCI::Error, conclusion.inspect) { Run.new(jobs: [publish_job(conclusion)]).restore(2) }
      assert_equal "Release artifacts are missing after publication was attempted; recover the original files.", error.message
    end
  end

  def test_the_upload_step_is_found_on_a_later_page_of_jobs
    filler = Array.new(100) { |index| {"name" => "job #{index}", "steps" => []} }
    run = Run.new(jobs: filler + [publish_job("success")])
    assert_raises(ReleaseCI::Error) { run.restore(2) }
    assert_equal 2, run.queries.count { |path| path.include?("/jobs?") }
  end

  def test_the_command_writes_the_output_the_workflow_reads
    Dir.mktmpdir("libtmux-ruby-release-ci-") do |directory|
      output = File.join(directory, "output")
      environment = {"GITHUB_REPOSITORY" => Run::REPOSITORY, "GITHUB_RUN_ID" => Run::ID, "GITHUB_RUN_ATTEMPT" => "1",
        "GITHUB_OUTPUT" => output}
      [[[], /No retained rubygems-release/, "retained=false\n"],
       [["rubygems-release"], %r{Restored rubygems-release into pkg/release}, "retained=false\nretained=true\n"]].each do |artifacts, message, written|
        run = Run.new(artifacts: artifacts)
        ci = ReleaseCI.new(client: run.client, downloader: ->(*) {})
        assert_output(message) { assert_equal 0, ReleaseCI.run(["restore", "pkg/release"], environment, ci: ci) }
        assert_equal written, File.read(output)
      end
    end
  end

  def test_the_command_refuses_other_arguments_and_a_missing_environment
    assert_output(nil, /usage: scripts\/release-ci check COMMIT/) { assert_equal 2, ReleaseCI.run([]) }
    assert_output(nil, /usage:/) { assert_equal 2, ReleaseCI.run(["restore"]) }
    assert_output(nil, /usage:/) { assert_equal 2, ReleaseCI.run(%w[check one two]) }
    assert_output(nil, /GITHUB_REPOSITORY/) { assert_equal 1, ReleaseCI.run(["restore", "pkg/release"], {}) }
    assert_output(nil, /release requires a full commit SHA/) { assert_equal 1, ReleaseCI.run(%w[check HEAD]) }
  end
end
