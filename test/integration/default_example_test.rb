# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/default_example_harness"

class DefaultExampleTest < Minitest::Test
  EXAMPLE = File.expand_path("../../examples/default_session.rb", __dir__)
  OPTIONS = ["-I", File.expand_path("../../gems/libtmux/lib", __dir__)].freeze

  def test_unchanged_ordinary_example_uses_harness_endpoint_and_cleans_its_session
    host = ENV.to_h
    evidence = run_example
    assert evidence.fetch(:status).success?, evidence.fetch(:stderr)
    assert_equal "session windows: 1\n", evidence.fetch(:stdout)
    assert_equal ["fixture"], evidence.fetch(:sessions)
    assert_equal host, ENV.to_h
    assert_retired(evidence)
  end

  def test_example_body_failure_still_removes_the_created_session
    evidence = run_example(injection: <<~RUBY)
      require "libtmux"
      module FailExampleBody
        def list_windows(**options)
          super
          raise "example body failed"
        end
      end
      LibTmux::Session.prepend(FailExampleBody)
    RUBY
    refute evidence.fetch(:status).success?
    assert_includes evidence.fetch(:stderr), "example body failed"
    assert_equal ["fixture"], evidence.fetch(:sessions)
    assert_retired(evidence)
  end

  def test_example_cleanup_failure_is_visible_and_harness_retires_its_daemon
    evidence = run_example(injection: <<~RUBY)
      require "libtmux"
      module FailExampleCleanup
        def destroy_owned(*, **)
          raise "example cleanup failed"
        end
      end
      LibTmux::Server.prepend(FailExampleCleanup)
    RUBY
    refute evidence.fetch(:status).success?
    assert_includes evidence.fetch(:stderr), "example cleanup failed"
    assert_equal 1, evidence.fetch(:sessions).count { |name| name.start_with?("ruby-example-") }
    assert_retired(evidence)
  end

  def test_both_example_body_and_cleanup_failures_survive
    evidence = run_example(injection: <<~RUBY)
      require "libtmux"
      module FailBothExampleOperations
        def list_windows(**)
          raise "body witness"
        end
      end
      module FailBothExampleCleanup
        def destroy_owned(*, **)
          raise "cleanup witness"
        end
      end
      LibTmux::Session.prepend(FailBothExampleOperations)
      LibTmux::Server.prepend(FailBothExampleCleanup)
      at_exit do
        failure = $!
        if failure.is_a?(LibTmux::CleanupError)
          warn "retained: \#{failure.body_error.message}; \#{failure.cleanup_error.message}"
        end
      end
    RUBY
    refute evidence.fetch(:status).success?
    assert_includes evidence.fetch(:stderr), "retained: body witness; cleanup witness"
    assert_retired(evidence)
  end

  def test_child_environment_overrides_preserve_absent_and_existing_host_values
    host = ENV.to_h
    [nil, "existing"].each do |value|
      child = host.merge("LIBTMUX_RUBY_HARNESS" => value)
      child["LIBTMUX_RUBY_HARNESS"] = "first"
      child["LIBTMUX_RUBY_HARNESS"] = "second"
      evidence = run_example(environment: child, injection: 'raise "child failed"')
      refute evidence.fetch(:status).success?
      assert_equal host, ENV.to_h
      assert_retired(evidence)
    end
  end

  def test_timed_out_example_retires_its_worker_and_fixture
    host = ENV.to_h
    assert_raises(LibTmux::DeadlineExceeded) do
      run_example(timeout: 0.1, injection: 'loop { sleep 10 }')
    end
    assert_equal host, ENV.to_h
  end

  def test_crashed_example_worker_still_retires_the_fixture
    evidence = run_example(injection: 'Process.kill("KILL", Process.pid)')
    assert evidence.fetch(:status).signaled?
    assert_equal Signal.list.fetch("KILL"), evidence.fetch(:status).termsig
    assert_equal ["fixture"], evidence.fetch(:sessions)
    assert_retired(evidence)
  end

  def test_lifecycle_examples_run_unchanged_with_external_endpoint_defaults
    {"lifecycle.rb" => "session reused: true\npane created: true\nadopted panes: 1\n",
      "lifecycle_discovery.rb" => "servers: 1\n"}.each do |program, expected|
      example = File.expand_path("../../examples/#{program}", __dir__)
      evidence = LibTmuxTest::DefaultExampleHarness.run(example: example, ruby_options: OPTIONS)
      assert evidence.fetch(:status).success?, evidence.fetch(:stderr)
      assert_equal expected, evidence.fetch(:stdout)
      assert_equal ["fixture"], evidence.fetch(:sessions)
      assert_retired(evidence)
    end
  end

  private

  def run_example(**options)
    LibTmuxTest::DefaultExampleHarness.run(example: EXAMPLE, ruby_options: OPTIONS, **options)
  end

  def assert_retired(evidence)
    assert evidence.fetch(:retired_before_removal)
    assert_instance_of Process::Status, evidence.fetch(:daemon_status)
    assert_raises(Errno::ECHILD) { Process.waitpid(evidence.fetch(:daemon_pid), Process::WNOHANG) }
    assert_raises(Errno::ESRCH) { Process.kill(0, evidence.fetch(:daemon_pid)) }
    refute File.exist?(evidence.fetch(:root))
  end
end
