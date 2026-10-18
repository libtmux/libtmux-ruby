# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/async"
require "libtmux/mcp/cli"
require "libtmux/workspace/cli"
require_relative "../support/tmux_fixture"
require "json"
require "pty"
require "socket"
require "stringio"
require "tmpdir"

# Runs against whichever daemon LIBTMUX_TEST_TMUX names. The client defaults to
# the same executable; CI points LIBTMUX_VERSION_CHECK_CLIENT_TMUX at a supported
# client so releases below the minimum are refused by their daemon report.
class TmuxVersionCheckTest < Minitest::Test
  EXECUTABLE = ENV.fetch("LIBTMUX_TEST_TMUX", "tmux")
  CLIENT = ENV.fetch("LIBTMUX_VERSION_CHECK_CLIENT_TMUX", EXECUTABLE)
  RANKING = LibTmux::Internal::TmuxVersion
  REMEDY = /upgrade tmux and restart the server, or pin the previous libtmux release/

  def test_the_connected_daemon_decides_support_not_the_client
    with_fixture do |fixture|
      plant_sentinels(fixture)
      if refused?(fixture)
        error = assert_raises(LibTmux::UnsupportedFeatureError) { open_server(fixture) }
        assert_match(/tmux 3\.3a or newer is required/, error.message)
        assert_equal [:not_sent, :admission], [error.delivery, error.phase]
      else
        open_server(fixture) { |server| assert_equal ["$0"], server.list_sessions.map(&:id) }
      end
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
      assert_sentinels_unchanged(fixture)
    end
  end

  # CI names the lane it means to exercise, so a missing or mis-set
  # LIBTMUX_TEST_TMUX fails here instead of passing the other lane's tests.
  # Only a local run without a lane is skipped.
  def test_the_selected_daemon_is_the_lane_under_test
    expected = ENV["LIBTMUX_VERSION_CHECK_EXPECT"]
    skip "LIBTMUX_VERSION_CHECK_EXPECT names the lane in CI" if expected.nil? && !ENV["GITHUB_ACTIONS"]
    with_fixture do |fixture|
      case expected
      when "refused" then assert refused?(fixture)
      when "supported" then refute refused?(fixture)
      else flunk "LIBTMUX_VERSION_CHECK_EXPECT must be refused or supported, not #{expected.inspect}"
      end
    end
  end

  def test_an_alias_named_for_the_fence_or_the_probe_refuses_the_server
    with_fixture do |fixture|
      next assert_refused(fixture) if refused?(fixture)

      ["if-shel", "run-shel"].each do |name|
        assert fixture.tmux("set-option", "-s", "command-alias[77]", "#{name}=display-message -p hijacked").last.success?
        error = assert_raises(LibTmux::Error, name) { open_server(fixture) }
        assert_equal :not_sent, error.delivery
        assert_equal :admission, error.phase
        assert fixture.tmux("set-option", "-su", "command-alias[77]").last.success?
      end
      open_server(fixture) { |server| assert_equal daemon_version(fixture), server.tmux_version }
    end
  end

  def test_version_timeout_is_a_validated_option
    with_fixture do |fixture|
      next assert_refused(fixture) if refused?(fixture)

      [0, -1, "5", Float::INFINITY].each do |value|
        assert_raises(ArgumentError) { open_server(fixture, version_timeout: value) }
      end
      open_server(fixture, version_timeout: 10) { |server| assert_equal ["$0"], server.list_sessions.map(&:id) }
    end
  end

  def test_supported_daemons_keep_raw_batches_and_typed_reads
    with_fixture do |fixture|
      next assert_refused(fixture) if refused?(fixture)
      open_server(fixture) do |server|
        assert_equal ["$0"], server.list_sessions.map(&:id)
        result = server.run(["set-option", "-g", "@libtmux-version-check", "accepted;", "display-message", "-p", "--", '#{version}'])
        assert result.success?
        assert_equal daemon_version(fixture), result.stdout.strip
        assert_equal "accepted", fixture.tmux("show-option", "-gv", "@libtmux-version-check").first.strip
      end
    end
  end

  def test_unsupported_daemon_is_refused_by_the_workspace_and_mcp_entry_points_without_effects
    with_fixture do |fixture|
      next assert_supported(fixture) unless refused?(fixture)
      config = File.join(File.dirname(fixture.socket_path), "refused.json")
      File.write(config, JSON.generate({session_name: "refused-workspace", windows: [{window_name: "one", panes: [{}]}]}))
      out, err = StringIO.new, StringIO.new
      status = LibTmux::Workspace::CLI.run(["load", config, "--json", "--socket", fixture.socket_path], out: out, err: err, environment: {})
      refute_equal 0, status
      failure = JSON.parse(out.string).fetch("error")
      assert_equal "tmux_unsupported", failure.fetch("kind")
      assert_equal %w[not_sent admission], failure.values_at("delivery", "phase")
      assert_match(/tmux 3\.3a or newer is required/, failure.fetch("message"))
      assert_match(REMEDY, failure.fetch("message"))
      refute fixture.tmux("has-session", "-t", "=refused-workspace").last.success?

      out, err = StringIO.new, StringIO.new
      status = LibTmux::Workspace::CLI.run(["load", config, "--socket", fixture.socket_path], out: out, err: err, environment: {})
      refute_equal 0, status
      assert_match(/tmux 3\.3a or newer is required/, err.string)
      assert_match(REMEDY, err.string)
      refute_match(/Workspace execution failed/, err.string)
      refute fixture.tmux("has-session", "-t", "=refused-workspace").last.success?

      input, closed = IO.pipe
      closed.close
      output, protocol = IO.pipe
      errors = StringIO.new
      status = LibTmux::MCP::CLI.run(["--socket", fixture.socket_path, "--tmux", CLIENT], input: input, out: protocol, err: errors)
      protocol.close
      assert_equal 1, status
      assert_empty output.read
      assert_match(/MCP refused to start: tmux 3\.3a or newer is required/, errors.string)
      assert_equal ["fixture"], fixture.tmux("list-sessions", "-F", '#{session_name}').first.lines.map(&:chomp)
    end
  end

  def test_unsupported_daemon_is_refused_by_owned_startup_before_the_daemon_starts
    with_fixture do |fixture|
      next assert_supported(fixture) unless refused?(fixture)
      error = assert_raises(LibTmux::UnsupportedFeatureError) { LibTmux::Server.start(executable: EXECUTABLE) }
      assert_equal :not_sent, error.delivery
    end
  end

  # An after-display-message hook fires for display-message on every release
  # and command-error fires for any failing command from 3.5. The probe and the
  # fence are neither.
  def test_version_check_and_dispatch_fire_no_user_hooks
    with_fixture do |fixture|
      next assert_refused(fixture) if refused?(fixture)
      # Read the release first: display-message fires the hook set below.
      release = RANKING.parse(daemon_version(fixture))
      assert fixture.tmux("set-hook", "-g", "after-display-message", "set-option -g @hook-display fired ; wait-for -S hook-display").last.success?
      error_hook = fixture.tmux("set-hook", "-g", "command-error", "set-option -g @hook-error fired ; wait-for -S hook-error").last.success?
      assert_equal release >= RANKING.parse("3.5"), error_hook, "command-error hooks exist from tmux 3.5"
      open_server(fixture) do |server|
        assert_equal ["$0"], server.list_sessions.map(&:id)
        assert server.run(["set-option", "-g", "@hook-probe", "ran"]).success?
      end
      assert_equal "", fixture.tmux("show-option", "-gqv", "@hook-display").first
      assert_equal "", fixture.tmux("show-option", "-gqv", "@hook-error").first

      fixture.tmux("display-message", "-p", "control")
      assert fixture.tmux("wait-for", "hook-display").last.success?
      assert_equal "fired", fixture.tmux("show-option", "-gqv", "@hook-display").first.strip
      next unless error_hook

      fixture.tmux("has-session", "-t", "=no-such-session")
      assert fixture.tmux("wait-for", "hook-error").last.success?
      assert_equal "fired", fixture.tmux("show-option", "-gqv", "@hook-error").first.strip
    end
  end

  def test_a_dispatch_after_the_daemon_changes_is_refused_without_effects
    with_fixture do |fixture|
      next assert_refused(fixture) if refused?(fixture)
      Dir.mktmpdir("libtmux-ruby-version-check-") do |directory|
        wrapper, claim = %w[selected-tmux claimed-version].map { |name| File.join(directory, name) }
        File.write(wrapper, <<~SH)
          #!/bin/sh
          for argument; do
            case $argument in
              libtmux-version-*'\#{version}')
                if [ -f #{shell(claim)} ]; then
                  printf 'unknown command: %s%s\\n' "${argument%'\#{version}'}" "$(cat #{shell(claim)})" >&2
                  exit 1
                fi;;
            esac
          done
          exec #{shell(CLIENT_PATH.call)} "$@"
        SH
        File.chmod(0o700, wrapper)
        batch = ["set-option", "-g", "@libtmux-refused", "changed;", "new-session", "-d", "-s", "must-not-exist"]
        sentinel = -> { [fixture.tmux("show-option", "-gqv", "@libtmux-refused").first, fixture.tmux("has-session", "-t", "=must-not-exist").last.success?] }

        # The probe reports the true release, so the same batch is dispatched.
        LibTmux::Server.open(socket_path: fixture.socket_path, executable: wrapper) do |server|
          assert server.run(batch).success?
        end
        assert_equal ["changed", true], [sentinel.call.first.strip, sentinel.call.last]
        fixture.tmux("set-option", "-gu", "@libtmux-refused")
        fixture.tmux("kill-session", "-t", "=must-not-exist")

        stale = daemon_version(fixture) == "3.3a" ? "3.4" : "3.3a"
        File.write(claim, stale)
        LibTmux::Server.open(socket_path: fixture.socket_path, executable: wrapper) do |server|
          error = assert_raises(LibTmux::UnsupportedFeatureError) { server.run(batch) }
          assert_equal [:not_sent, :admission], [error.delivery, error.phase]
          assert_match(/no longer reports #{Regexp.escape(stale)}/, error.message)
          assert_raises(LibTmux::UnsupportedFeatureError) { server.list_sessions }
          assert_raises(LibTmux::UnsupportedFeatureError) { server.new_session(name: "must-not-exist", command: ["/bin/cat"]) }
          assert_raises(LibTmux::UnsupportedFeatureError) { server.snapshot }
          Async do |parent|
            LibTmux::Async.open(parent: parent, server: server) do |scope|
              assert_raises(LibTmux::UnsupportedFeatureError) { scope.server.run(batch) }
              assert_raises(LibTmux::UnsupportedFeatureError) { scope.server.list_sessions }
              app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test", enabled_tools: %w[tmux_snapshot])
              begin
                failure = app.call("tmux_snapshot", {"entity" => "pane", "limit" => 1}).structured_content.fetch("error")
              ensure
                app.close
              end
              assert_equal %w[unsupported not_sent], failure.values_at("code", "delivery")
              assert_match(/\Atmux 3\.3a or newer is required.*upgrade tmux and restart the server\z/, failure.fetch("message"))
            end
          end.wait
        end
        assert_equal ["", false], sentinel.call
      end
    end
  end

  # tmux 3.2 added -N, which keeps a client from starting a daemon. Every
  # client the library spawns for a bound endpoint carries it, so a stale
  # route can never start the daemon it was meant to reach.
  def test_every_client_spawn_for_a_bound_endpoint_refuses_to_start_a_daemon
    with_fixture do |fixture|
      next assert_refused(fixture) if refused?(fixture)
      Dir.mktmpdir("libtmux-ruby-version-check-") do |directory|
        wrapper, calls = %w[selected-tmux calls].map { |name| File.join(directory, name) }
        File.write(wrapper, <<~SH)
          #!/bin/sh
          printf '%s\\n' "$*" >> #{shell(calls)}
          exec #{shell(CLIENT_PATH.call)} "$@"
        SH
        File.chmod(0o700, wrapper)
        LibTmux::Server.open(socket_path: fixture.socket_path, executable: wrapper) do |server|
          server.list_sessions
          server.open_control(session: server.list_sessions.first.ref) { |control| control.exchange("display-message -p control") }
          PTY.open do |_master, slave|
            slave.winsize = [24, 80]
            assert_raises(LibTmux::DeadlineExceeded) do
              server.attach(session: server.list_sessions.first.ref, terminal: slave, term: "xterm", timeout: 0.3)
            end
          end
        end
        lines = File.readlines(calls, chomp: true)
        lines.each { |line| assert_match(/\A-u -N -S /, line) }
        assert(lines.any? { |line| line.include?("attach-session") })
        assert(lines.any? { |line| line.include?(" -C attach-session") })
      end
    end
  end

  # A daemon older than tmux 3.2 keeps the client's stdout pipe open after the
  # client exits. The probe's answer is on stderr and in the exit status, so
  # the refusal must not wait for stdout.
  def test_a_pre_3_2_refusal_returns_while_a_descendant_holds_stdout_open
    Dir.mktmpdir("libtmux-ruby-version-check-") do |directory|
      socket = File.join(directory, "socket")
      UNIXServer.new(socket).close
      wrapper, answer, holder = %w[selected-tmux answer holder].map { |name| File.join(directory, name) }
      File.write(wrapper, <<~SH)
        #!/bin/sh
        sleep 30 < /dev/null 2> /dev/null &
        printf '%s' "$!" > #{shell(holder)}
        cat #{shell(answer)} >&2
        exit 1
      SH
      File.chmod(0o700, wrapper)
      begin
        ["usage: run-shell [-b] [-t target-pane] shell-command\n", "server version is too old for client\n"].each do |stderr|
          File.write(answer, stderr)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          error = assert_raises(LibTmux::UnsupportedFeatureError, stderr) { LibTmux::Server.open(socket_path: socket, executable: wrapper) }
          assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.0
          assert_equal [:not_sent, :admission], [error.delivery, error.phase]
          assert_match(/older than 3\.2/, error.message)
        end
        File.write(answer, "usage: run-shell [-bC] [-d delay] [-t target-pane] [shell-command]\n")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = assert_raises(LibTmux::CommandError) { LibTmux::Server.open(socket_path: socket, executable: wrapper) }
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.0
        assert_equal :not_sent, error.delivery
      ensure
        Process.kill("KILL", File.read(holder).to_i) if File.exist?(holder)
      end
    end
  end

  def test_owned_startup_checks_the_executable_before_every_daemon
    with_fixture do |fixture|
      next assert_refused(fixture) if refused?(fixture)
      Dir.mktmpdir("libtmux-ruby-version-check-") do |directory|
        wrapper, calls, rejected = %w[selected-tmux calls rejected].map { |name| File.join(directory, name) }
        File.write(wrapper, <<~SH)
          #!/bin/sh
          printf '%s\\n' "$*" >> #{shell(calls)}
          if [ "$1" = -V ] && [ -f #{shell(rejected)} ]; then printf 'tmux 3.3\\n'; exit 0; fi
          exec #{shell(CLIENT_PATH.call)} "$@"
        SH
        File.chmod(0o700, wrapper)
        LibTmux::Server.start(executable: wrapper) { |server| assert server.owned? }
        File.write(rejected, "changed")
        File.write(calls, "")
        error = assert_raises(LibTmux::UnsupportedFeatureError) { LibTmux::Server.start(executable: wrapper) }
        assert_equal :not_sent, error.delivery
        assert_equal ["-V"], File.readlines(calls, chomp: true)
      end
    end
  end

  def test_owned_startup_accepts_renamed_and_binary_executable_names
    with_fixture do |fixture|
      next assert_refused(fixture) if refused?(fixture)
      Dir.mktmpdir("libtmux-ruby-version-check-") do |directory|
        started = []
        ["selected tmux", "selected-\xFF".b].each do |name|
          selected = File.join(directory, name)
          begin
            File.symlink(CLIENT_PATH.call, selected)
          rescue Errno::EILSEQ
            # APFS rejects file names that are not valid UTF-8.
            raise unless RUBY_PLATFORM.include?("darwin") && !name.dup.force_encoding(Encoding::UTF_8).valid_encoding?
            next
          end
          LibTmux::Server.start(executable: selected) { |server| assert server.owned? }
          started << name
        end
        assert_includes started, "selected tmux"
        assert_equal 2, started.length unless RUBY_PLATFORM.include?("darwin")
      end
    end
  end

  def test_an_endpoint_without_a_running_daemon_is_not_supported
    Dir.mktmpdir("libtmux-ruby-version-check-") do |directory|
      socket = File.join(directory, "socket")
      UNIXServer.new(socket).close
      error = assert_raises(LibTmux::TargetNotFoundError) { LibTmux::Server.open(socket_path: socket, executable: CLIENT) }
      assert_equal [:not_sent, :admission], [error.delivery, error.phase]
      assert_raises(LibTmux::TargetNotFoundError) { LibTmux::Server.open(socket_path: File.join(directory, "missing"), executable: CLIENT) }
    end
  end

  private

  CLIENT_PATH = -> { LibTmux::Endpoint.new(socket_name: "unused", executable: CLIENT).executable }
  private_constant :CLIENT_PATH

  # A test that applies to one kind of daemon asserts the other kind instead,
  # so a mis-set LIBTMUX_TEST_TMUX cannot pass vacuously.
  def assert_refused(fixture)
    assert_raises(LibTmux::UnsupportedFeatureError) { open_server(fixture) }
  end

  def assert_supported(fixture)
    open_server(fixture) { |server| assert_equal daemon_version(fixture), server.tmux_version }
  end

  def plant_sentinels(fixture)
    assert fixture.tmux("set-option", "-g", "@sentinel", "planted").last.success?
    assert fixture.tmux("set-buffer", "-b", "sentinel", "planted").last.success?
  end

  def assert_sentinels_unchanged(fixture)
    assert_equal "planted", fixture.tmux("show-option", "-gqv", "@sentinel").first.strip
    assert_equal ["sentinel"], fixture.tmux("list-buffers", "-F", '#{buffer_name}').first.lines.map(&:chomp)
    assert_equal "planted", fixture.tmux("show-buffer", "-b", "sentinel").first
    assert_equal ["fixture"], fixture.tmux("list-sessions", "-F", '#{session_name}').first.lines.map(&:chomp)
  end

  def with_fixture
    fixture = LibTmuxTest::TmuxFixture.new(executable: EXECUTABLE)
    fixture.start
    yield fixture
  ensure
    fixture&.close
  end

  def open_server(fixture, **options, &block)
    LibTmux::Server.open(socket_path: fixture.socket_path, executable: CLIENT, **options, &block)
  end

  def daemon_version(fixture)
    fixture.tmux("display-message", "-p", '#{version}').first.strip
  end

  def refused?(fixture)
    RANKING.parse(daemon_version(fixture)) < RANKING.parse(RANKING::MINIMUM)
  end

  def shell(value)
    "'#{value.gsub("'") { %q('\'') }}'"
  end
end
