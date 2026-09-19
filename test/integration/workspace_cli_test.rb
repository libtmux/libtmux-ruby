# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/workspace/cli"
require "stringio"
require "pty"

class WorkspaceCLIIntegrationTest < Minitest::Test
  def test_live_plan_detached_load_and_conflict_return_distinct_json_results
    LibTmuxTest::TmuxFixture.open do |fixture|
      file = write_config(fixture, "cli")
      status, value, diagnostics = cli(fixture, ["plan", "--live", file])
      assert_equal 0, status
      assert_equal "captured_create", value.fetch("mode")
      assert value.fetch("preconditions").fetch("binding_key")
      assert_empty diagnostics
      assert_equal 1, fixture.tmux("list-sessions", "-F", '#{session_id}').first.lines.length
      status, value, diagnostics = cli(fixture, ["load", file])
      assert_equal 0, status
      assert_equal true, value.fetch("success")
      assert_equal 3, value.fetch("created_refs").length
      assert_empty diagnostics
      assert_empty fixture.tmux("list-clients").first
      status, value, = cli(fixture, ["load", file])
      assert_equal 1, status
      assert_equal "application", value.fetch("error").fetch("kind")
      assert_empty value.fetch("result").fetch("effects")
    end
  end

  def test_partial_application_and_interrupt_keep_the_ledger_with_distinct_exit_codes
    LibTmuxTest::TmuxFixture.open do |fixture|
      original = LibTmux::Options.instance_method(:set)
      begin
        LibTmux::Options.define_method(:set) do |*arguments, **options|
          raise LibTmux::TransportError.new("private-payload", delivery: :not_sent)
        end
        status, value, diagnostics = cli(fixture, ["load", write_config(fixture, "partial")])
        assert_equal 3, status
        assert_equal 3, value.fetch("result").fetch("created_refs").length
        refute_includes JSON.generate(value), "private-payload"
        assert_empty diagnostics
      ensure
        LibTmux::Options.define_method(:set, original)
      end
      trace = TracePoint.new(:return) do |point|
        next unless point.self.is_a?(LibTmux::Server) && point.method_id == :new_session

        trace.disable
        Thread.current.raise(Interrupt.new("private-interruption"))
      end
      begin
        trace.enable
        status, value, diagnostics = cli(fixture, ["load", write_config(fixture, "interrupted")])
        assert_equal 130, status
        assert_equal "interrupted", value.fetch("error").fetch("kind")
        assert_equal 3, value.fetch("result").fetch("created_refs").length
        refute_includes JSON.generate(value), "private-interruption"
        assert_empty diagnostics
      ensure
        trace.disable
      end
    end
  end

  def test_explicit_attach_owns_only_its_terminal_client_and_returns_after_user_detach
    LibTmuxTest::TmuxFixture.open do |fixture|
      master, terminal = PTY.open
      open_file = File.method(:open)
      worker = nil
      begin
        File.define_singleton_method(:open) do |*arguments, **options, &block|
          if arguments.first == "/dev/tty"
            block.call(terminal)
          else
            open_file.call(*arguments, **options, &block)
          end
        end
        config = write_config(fixture, "attached")
        output, diagnostics = StringIO.new, StringIO.new
        worker = Thread.new do
          LibTmux::Workspace::CLI.run(["load", config, "--json", "--socket", fixture.socket_path, "--attach"],
            out: output, err: diagnostics, environment: {"TERM" => "xterm"})
        end
        assert IO.select([master], nil, nil, 0.5), "attached client did not draw its terminal"
        assert master.read_nonblock(65_536).bytesize.positive?
        master.write("\x02d")
        assert worker.join(0.5), "attached client did not exit after user detach"
        assert_equal 0, worker.value
        assert_equal true, JSON.parse(output.string).fetch("success")
        assert_empty diagnostics.string
        assert_empty fixture.tmux("list-clients").first
        assert_equal ["attached", "fixture"], fixture.tmux("list-sessions", "-F", '#{session_name}').first.lines.map(&:chomp).sort
      ensure
        worker.raise(Interrupt) if worker&.alive?
        worker&.join(0.5)
        File.define_singleton_method(:open, open_file)
        master.close
        terminal.close
      end
    end
  end

  private

  def write_config(fixture, name)
    file = File.join(File.dirname(fixture.socket_path), "#{name}.json")
    File.write(file, JSON.generate({session_name: name, windows: [{window_name: "one", panes: [{}]}]}))
    file
  end

  def cli(fixture, arguments)
    output, diagnostics = StringIO.new, StringIO.new
    status = LibTmux::Workspace::CLI.run([*arguments, "--json", "--socket", fixture.socket_path], out: output, err: diagnostics, environment: {})
    [status, JSON.parse(output.string), diagnostics.string]
  end
end
