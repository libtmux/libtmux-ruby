# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "libtmux/group" if File.exist?(File.expand_path("../../gems/libtmux/lib/libtmux/group.rb", __dir__))

class GroupTest < Minitest::Test
  def test_runtime_failure_keeps_earlier_effects_and_does_not_invent_step_statuses
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        result = server.run_group([
          ["set-option", "-g", "@group-first", "literal;"],
          ["select-pane", "-t", "%4294967294"],
          ["set-option", "-g", "@group-last", "must-not-run"]
        ])
        refute result.success?
        assert_equal :observed, result.delivery
        assert_equal 3, result.steps.size
        assert result.steps.frozen?
        assert result.steps.all? { |step| step.fetch(:outcome) == :unknown }
        assert_equal "literal;\n", server.run(["show-options", "-g", "-v", "@group-first"]).text
        refute server.options(scope: :session).list.any? { |option| option.name == "@group-last" }
        assert_instance_of LibTmux::CommandResult, result.result
        refute_includes result.inspect, "literal"
        success = server.run_group([["display-message", "-p", "a"], ["display-message", "-p", "b"]])
        assert success.success?
        assert_equal "a\nb\n", success.result.text
        assert success.steps.all? { |step| step.fetch(:outcome) == :unknown }
      end
    end
  end

  def test_group_validation_and_pre_cancel_refuse_before_any_effect
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        command = ["set-option", "-g", "@group-never", "no"]
        [[], [command, []], [command, ["display-message", "\0"]], [["-S", "unrelated"]]].each do |commands|
          assert_raises(ArgumentError) { server.run_group(commands) }
        end
        assert_raises(LibTmux::CapacityError) { server.run_group(Array.new(129, command)) }
        token = LibTmux::Internal::Cancellation.new
        begin
          token.cancel
          failure = assert_raises(LibTmux::Cancelled) { server.run_group([command], cancel: token) }
          assert_equal :not_sent, failure.delivery
        ensure
          token.close
        end
        refute server.options(scope: :session).list.any? { |option| option.name == "@group-never" }
      end
    end
  end

  def test_cancellation_retires_the_client_without_undoing_observed_earlier_effects
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        token = LibTmux::Internal::Cancellation.new
        worker = Thread.new do
          server.run_group([
            ["set-option", "-g", "@group-effect", "already-applied"],
            ["wait-for", "-S", "group-ready"],
            ["wait-for", "group-held"],
            ["set-option", "-g", "@group-later", "uncertain"]
          ], cancel: token)
        rescue LibTmux::Cancelled => error
          error
        end
        begin
          assert fixture.tmux("wait-for", "group-ready").last.success?
          token.cancel
          assert worker.join(0.5), "cancelled group client did not retire"
          failure = worker.value
          assert_instance_of LibTmux::Cancelled, failure
          assert_equal :possibly_sent, failure.delivery
          assert_raises(Errno::ECHILD) { Process.waitpid(failure.pid, Process::WNOHANG) }
          assert_equal "already-applied\n", server.run(["show-options", "-g", "-v", "@group-effect"]).text
        ensure
          token.cancel
          fixture.tmux("wait-for", "-S", "group-held")
          worker.join(0.5)
          token.close
        end
      end
    end
  end
end
