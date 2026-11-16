# frozen_string_literal: true

require_relative "../../../test/test_helper"
require "open3"
require_relative "../../ci-plan/ci_manifest"

load File.expand_path("../version-check", __dir__) unless defined?(VersionCheck)

class VersionCheckTest < Minitest::Test
  SCRIPT = File.expand_path("../version-check", __dir__)

  def test_every_check_the_manifest_allows_has_a_test_file
    assert_equal CIManifest::CHECKS.sort, VersionCheck::TESTS.keys.sort
    VersionCheck::TESTS.each_value { |test| assert File.file?(File.join(VersionCheck::ROOT, test.fetch(:file))), test.fetch(:file) }
  end

  def test_an_old_daemon_runs_its_own_test_against_its_exact_release_under_a_deadline
    plan = VersionCheck.plan("old_daemon", "3.1c")
    assert_equal({"LIBTMUX_VERSION_CHECK_EXPECT" => "3.1c"}, plan.fetch(:env))
    assert_equal [Gem.ruby, "-Itest", "test/old_daemon/pre_3_2_refusal_test.rb"], plan.fetch(:argv)
    assert_equal 120, plan.fetch(:deadline)
  end

  def test_a_refused_release_runs_the_version_check_test_expecting_refusal
    plan = VersionCheck.plan("refused", "3.3")
    assert_equal({"LIBTMUX_VERSION_CHECK_EXPECT" => "refused"}, plan.fetch(:env))
    assert_equal [Gem.ruby, "-Itest", "test/integration/tmux_version_check_test.rb"], plan.fetch(:argv)
    assert_nil plan.fetch(:deadline)
  end

  def test_an_unknown_check_fails_and_names_the_release
    _, error, status = Open3.capture3(Gem.ruby, "--disable=gems,rubyopt", SCRIPT, "skip", "3.9")
    assert_equal 1, status.exitstatus
    assert_equal "no version-check test is assigned to tmux 3.9\n", error
  end

  def test_a_call_without_both_arguments_prints_the_usage
    _, error, status = Open3.capture3(Gem.ruby, "--disable=gems,rubyopt", SCRIPT, "refused")
    assert_equal 2, status.exitstatus
    assert_match(/\Ausage: scripts\/version-check\/version-check CHECK TMUX_VERSION/, error)
  end

  def test_the_exit_status_of_the_test_is_the_status_of_the_check
    assert_equal 0, VersionCheck.execute({env: {}, argv: [Gem.ruby, "--disable=gems,rubyopt", "-e", "exit 0"], deadline: nil})
    assert_equal 3, VersionCheck.execute({env: {}, argv: [Gem.ruby, "--disable=gems,rubyopt", "-e", "exit 3"], deadline: nil})
  end

  def test_a_test_that_outlives_its_deadline_is_stopped_with_status_124
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = nil
    _, error = capture_io { status = VersionCheck.execute({env: {}, argv: [Gem.ruby, "--disable=gems,rubyopt", "-e", "sleep 30"], deadline: 0.2}) }
    assert_equal 124, status
    assert_match(/did not finish in 0.2 seconds/, error)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end
end
