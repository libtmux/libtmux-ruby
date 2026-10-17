# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/async"
require "libtmux/mcp/cli"
require "libtmux/workspace/cli"
require_relative "../support/tmux_fixture"
require "json"
require "socket"
require "stringio"
require "tmpdir"

# Runs against whichever daemon LIBTMUX_TEST_TMUX names. The client defaults to
# the same executable; CI points LIBTMUX_VERSION_CHECK_CLIENT_TMUX at a supported
# client so releases below the minimum are refused by their daemon report.
class TmuxVersionCheckTest < Minitest::Test
  EXECUTABLE = ENV.fetch("LIBTMUX_TEST_TMUX", "tmux")
  CLIENT = ENV.fetch("LIBTMUX_VERSION_CHECK_CLIENT_TMUX", EXECUTABLE)
  REFUSED = %w[3.2a 3.3].freeze

  def test_the_connected_daemon_decides_support_not_the_client
    with_fixture do |fixture|
      if refused?(fixture)
        error = assert_raises(LibTmux::UnsupportedFeatureError) { open_server(fixture) }
        assert_match(/tmux 3\.3a or newer is required/, error.message)
        assert_equal [:not_sent, :admission], [error.delivery, error.phase]
      else
        open_server(fixture) { |server| assert_equal ["$0"], server.list_sessions.map(&:id) }
      end
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
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
      assert_equal "execution", JSON.parse(out.string).fetch("error").fetch("kind")
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
      assert fixture.tmux("set-hook", "-g", "after-display-message", "set-option -g @hook-display fired ; wait-for -S hook-display").last.success?
      error_hook = fixture.tmux("set-hook", "-g", "command-error", "set-option -g @hook-error fired ; wait-for -S hook-error").last.success?
      open_server(fixture) do |server|
        assert_equal ["$0"], server.list_sessions.map(&:id)
        assert server.run(["set-option", "-g", "@hook-probe", "ran"]).success?
      end
      assert_equal "", fixture.tmux("show-option", "-gqv", "@hook-display").first
      assert_equal "", fixture.tmux("show-option", "-gqv", "@hook-error").first

      fixture.tmux("display-message", "-p", "control")
      assert fixture.tmux("wait-for", "hook-display").last.success?
      assert_equal "fired", fixture.tmux("show-option", "-gqv", "@hook-display").first.strip
      next refute(error_hook, "command-error hooks exist only from tmux 3.5") unless error_hook

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
            end
          end.wait
        end
        assert_equal ["", false], sentinel.call
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
        ["selected tmux", "selected-\xFF".b].each do |name|
          selected = File.join(directory, name)
          begin
            File.symlink(CLIENT_PATH.call, selected)
          rescue Errno::EILSEQ
            # APFS rejects file names that are not valid UTF-8.
            next
          end
          LibTmux::Server.start(executable: selected) { |server| assert server.owned? }
        end
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

  def with_fixture
    fixture = LibTmuxTest::TmuxFixture.new(executable: EXECUTABLE)
    fixture.start
    yield fixture
  ensure
    fixture&.close
  end

  def open_server(fixture, &block)
    LibTmux::Server.open(socket_path: fixture.socket_path, executable: CLIENT, &block)
  end

  def daemon_version(fixture)
    fixture.tmux("display-message", "-p", '#{version}').first.strip
  end

  def refused?(fixture)
    REFUSED.include?(daemon_version(fixture))
  end

  def shell(value)
    "'#{value.gsub("'") { %q('\'') }}'"
  end
end
