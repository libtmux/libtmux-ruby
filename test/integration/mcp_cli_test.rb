# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/mcp/cli"
require "stringio"
require "socket"
require "shellwords"

class McpCLIIntegrationTest < Minitest::Test
  def test_explicit_enrollment_file_serves_protocol_and_retires_pending_accept_on_eof
    LibTmuxTest::TmuxFixture.open do |fixture|
      next unless enrollment_supported?(fixture)

      LibTmux::Server.open(socket_path: fixture.socket_path, executable: fixture.executable) do |server|
        pane = server.list_panes.first
        setup = File.join(File.dirname(fixture.socket_path), "enroll shell's setup.zsh")
        reader, input = IO.pipe
        output, writer = IO.pipe
        errors = StringIO.new
        publications = []
        trace = TracePoint.new(:c_call) do |event|
          if event.method_id == :write && event.self.is_a?(File) && File.dirname(event.self.path) == File.dirname(setup)
            publications << File.exist?(setup)
          end
        end
        trace.enable
        worker = Thread.new do
          LibTmux::MCP::CLI.run(["--socket", fixture.socket_path,
            "--tmux", fixture.executable, "--enable-tool", "tmux_run",
            "--enroll-pane", "#{pane.id}=#{setup}"], input: reader, out: writer, err: errors)
        ensure
          writer.close
        end
        begin
          send_frame(input, id: 1, method: "initialize", params: {protocolVersion: "2025-11-25",
            capabilities: {}, clientInfo: {name: "test", version: "1"}})
          assert IO.select([output], nil, nil, 0.5), "enrollment CLI did not initialize"
          line = output.gets
          refute_nil line, "enrollment CLI closed protocol output: #{errors.string}"
          initialized = JSON.parse(line)
          trace.disable
          assert_equal "2025-11-25", initialized.dig("result", "protocolVersion")
          assert_equal [false], publications, "setup was visible before its complete source command was written"
          assert_equal 0o600, File.stat(setup).mode & 0o777
          source = File.read(setup)
          assert_equal 1, source.lines.length
          words = Shellwords.split(source)
          assert_equal "source", words.first
          assert_equal 7, words.length
          assert File.file?(words[1])
          assert File.socket?(words[2])
          input.close
          assert worker.join(0.5), "pending shell enrollment prevented EOF retirement"
          assert_equal 0, worker.value, errors.string
          refute File.exist?(setup)
          refute File.exist?(words[2])
          assert_empty errors.string
          assert fixture.tmux("has-session").last.success?
        ensure
          trace.disable
          input.close unless input.closed?
          worker.join(0.5)
          worker.raise(Interrupt) if worker.alive?
          worker.join(0.5)
          [reader, output, writer].each { |io| io.close unless io.closed? }
        end
      end
    end
  end

  def test_cli_serves_real_protocol_and_eof_preserves_the_borrowed_daemon
    LibTmuxTest::TmuxFixture.open do |fixture|
      reader, input = IO.pipe
      output, writer = IO.pipe
      errors = StringIO.new
      application_closes = []
      trace = TracePoint.new(:call) do |event|
        if event.defined_class == LibTmux::MCP::Application && event.method_id == :close
          application_closes << Fiber.scheduler
        end
      end
      worker = Thread.new do
        LibTmux::MCP::CLI.run(["--socket", fixture.socket_path, "--endpoint", "test"],
          input: reader, out: writer, err: errors)
      end
      begin
        send_frame(input, id: 1, method: "initialize", params: {protocolVersion: "2025-11-25",
          capabilities: {}, clientInfo: {name: "test", version: "1"}})
        assert_equal "2025-11-25", frame(output).dig("result", "protocolVersion")
        send_frame(input, method: "notifications/initialized")
        send_frame(input, id: 2, method: "tools/list")
        assert_equal %w[tmux_capabilities tmux_snapshot], frame(output).fetch("result").fetch("tools").map { |tool| tool.fetch("name") }
        send_frame(input, id: 3, method: "tools/call", params: {name: "tmux_capabilities", arguments: {}})
        result = frame(output).dig("result", "structuredContent")
        assert result.fetch("ok")
        assert_equal "test", result.fetch("data").fetch("endpoint")
        trace.enable
        input.close
        assert worker.join(0.5), "MCP CLI did not retire after EOF"
        assert_equal 0, worker.value
        assert_equal 1, application_closes.length
        refute_nil application_closes.first
        assert_empty errors.string
        assert fixture.tmux("has-session").last.success?
      ensure
        trace.disable
        input.close unless input.closed?
        worker.join(0.5)
        worker.raise(Interrupt) if worker.alive?
        worker.join(0.5)
        [reader, output, writer].each { |io| io.close unless io.closed? }
      end
    end
  end

  def test_existing_setup_file_or_symlink_is_preserved_when_enrollment_startup_fails
    LibTmuxTest::TmuxFixture.open do |fixture|
      next unless enrollment_supported?(fixture)

      LibTmux::Server.open(socket_path: fixture.socket_path, executable: fixture.executable) do |server|
        pane = server.list_panes.first
        other = pane.split(direction: :horizontal, command: ["cat"])
        provisional = File.join(File.dirname(fixture.socket_path), "provisional-setup")
        original = File.join(File.dirname(fixture.socket_path), "private-existing")
        link = File.join(File.dirname(fixture.socket_path), "private-link")
        File.write(original, "preserve this file\n")
        File.symlink(original, link)
        [original, link].each do |path|
          reader, input = IO.pipe
          output, writer = IO.pipe
          errors = StringIO.new
          status = LibTmux::MCP::CLI.run(["--socket", fixture.socket_path, "--tmux", fixture.executable,
            "--enable-tool", "tmux_run", "--enroll-pane", "#{pane.id}=#{provisional}",
            "--enroll-pane", "#{other.id}=#{path}"],
            input: reader, out: writer, err: errors)
          assert_equal 1, status
          assert_equal "preserve this file\n", File.read(original)
          assert File.symlink?(link)
          refute File.exist?(provisional), "earlier setup survived failed enrollment startup"
          assert_empty Dir[File.join(File.dirname(fixture.socket_path), ".libtmux-ruby-shell-*")]
          refute_includes errors.string, "private-"
          writer.close
          assert_empty output.read
          assert fixture.tmux("has-session").last.success?
        ensure
          [reader, input, output, writer].each { |io| io.close unless io.closed? }
        end
      end
    end
  end

  def test_explicitly_sourced_cli_setup_runs_a_script_through_the_protocol
    LibTmuxTest::TmuxFixture.open do |fixture|
      next unless enrollment_supported?(fixture)

      directory = File.dirname(fixture.socket_path)
      setup = File.join(directory, "source this setup.zsh")
      listener = UNIXServer.new(File.join(directory, "shell-ready"))
      File.write(File.join(directory, ".zshrc"), <<~ZSH)
        zmodload zsh/net/socket || exit 80
        zsocket '#{listener.path}' || exit 81
        typeset -g test_control=$REPLY
        print -r -- initializing >&$test_control
        IFS= read -r setup_file <&$test_control
        source "$setup_file" || exit 82
        export LIBTMUX_CLI_CONTEXT=literal-context
        PS1=''
        test_ready() { print -r -- ready >&$test_control }
        zle -N zle-line-init test_ready
      ZSH
      LibTmux::Server.open(socket_path: fixture.socket_path, executable: fixture.executable) do |server|
        pane = server.new_session(name: "cli-shell",
          command: ["/usr/bin/env", "ZDOTDIR=#{directory}", "/bin/zsh", "-d", "-i"]).list_panes.first
        assert IO.select([listener], nil, nil, 0.5), "owned shell did not connect"
        channel = listener.accept
        assert_equal "initializing", line(channel, label: "owned shell initialization")
        reader, input = IO.pipe
        output, writer = IO.pipe
        errors = StringIO.new
        worker = Thread.new do
          LibTmux::MCP::CLI.run(["--socket", fixture.socket_path, "--tmux", fixture.executable,
            "--enable-tool", "tmux_run", "--enroll-pane", "#{pane.id}=#{setup}"],
            input: reader, out: writer, err: errors)
        ensure
          writer.close
        end
        begin
          send_frame(input, id: 1, method: "initialize", params: {protocolVersion: "2025-11-25",
            capabilities: {}, clientInfo: {name: "test", version: "1"}})
          assert_equal "2025-11-25", frame(output).dig("result", "protocolVersion")
          send_frame(input, method: "notifications/initialized")
          channel.puts(setup)
          assert_equal "ready", line(channel, label: "shell enrollment acknowledgement")
          send_frame(input, id: 2, method: "tools/call", params: {name: "tmux_capabilities", arguments: {}})
          capabilities = frame(output).dig("result", "structuredContent", "data")
          target = {generation: capabilities.fetch("server_identity").fetch("generation"), kind: "pane", id: pane.id}
          script = 'printf "%s:%s" "$LIBTMUX_CLI_CONTEXT" "$TMUX_PANE"; printf "\\377" >&2; exit 9'
          send_frame(input, id: 3, method: "tools/call", params: {name: "tmux_run", arguments: {target: target, script: script}})
          response = frame(output).dig("result", "structuredContent")
          assert response.fetch("ok"), response.inspect
          result = response.fetch("data")
          assert_equal "literal-context:#{pane.id}", result.fetch("stdout").fetch("data")
          assert_equal({"encoding" => "base64", "data" => "/w==", "bytes" => 1, "truncated" => false}, result.fetch("stderr"))
          assert_equal({"state" => "exited", "exit_status" => 9, "signal" => nil}, result.fetch("completion"))
          assert_equal "authorized", result.fetch("authorization").fetch("state")
          send_frame(input, id: 4, method: "tools/call", params: {name: "tmux_run",
            arguments: {target: target, script: "printf ready", stdout_limit: 8, stderr_limit: 0}})
          repeated = frame(output).dig("result", "structuredContent")
          assert repeated.fetch("ok"), repeated.inspect
          assert_equal "ready", repeated.fetch("data").fetch("stdout").fetch("data")
          refute_equal result.fetch("authorization").fetch("run_id"), repeated.fetch("data").fetch("authorization").fetch("run_id")
          input.close
          assert worker.join(0.5), "enrolled CLI did not retire after EOF"
          assert_equal 0, worker.value, errors.string
          assert_empty errors.string
          refute File.exist?(setup)
          assert_empty Dir[File.join(directory, ".libtmux-ruby-shell-*")]
          assert server.run(["has-session", "-t", "cli-shell"]).success?
          assert_empty server.list_clients
        ensure
          input.close unless input.closed?
          worker.join(0.5)
          worker.raise(Interrupt) if worker.alive?
          worker.join(0.5)
          [reader, input, output, writer, channel].compact.each { |io| io.close unless io.closed? }
        end
      end
    ensure
      listener&.close
    end
  end

  private

  def enrollment_supported?(fixture)
    values, error, status = fixture.tmux("display-message", "-p", '#{version}|#{pane_id}')
    assert status.success?, error
    version, pane_id = values.strip.split("|")
    parts = /\A(\d+)\.(\d+)/.match(version)
    refute_nil parts, "tmux version must be known for the enrollment contract"
    return true if ([parts[1].to_i, parts[2].to_i] <=> [3, 3]) >= 0

    setup = File.join(File.dirname(fixture.socket_path), "unsupported-enrollment.zsh")
    reader, input = IO.pipe
    output, writer = IO.pipe
    errors = StringIO.new
    status = LibTmux::MCP::CLI.run(["--socket", fixture.socket_path, "--tmux", fixture.executable,
      "--enable-tool", "tmux_run", "--enroll-pane", "#{pane_id}=#{setup}"],
      input: reader, out: writer, err: errors)
    assert_equal 1, status
    assert_includes errors.string, "LibTmux::UnsupportedFeatureError"
    writer.close
    assert_empty output.read
    refute File.exist?(setup)
    assert_empty Dir[File.join(File.dirname(fixture.socket_path), ".libtmux-ruby-shell-*")]
    assert fixture.tmux("has-session").last.success?
    false
  ensure
    [reader, input, output, writer].compact.each { |io| io.close unless io.closed? }
  end

  def send_frame(io, **message)
    io.write(JSON.generate({jsonrpc: "2.0", **message}) + "\n")
  end

  def frame(io)
    JSON.parse(line(io))
  end

  def line(io, label: "CLI frame")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    @line_buffers ||= {}
    bytes = (@line_buffers[io] ||= +"".b)
    loop do
      ending = bytes.index("\n")
      return bytes.slice!(0, ending + 1).chomp if ending

      raise "CLI frame exceeded its limit" if bytes.bytesize > 1 << 20

      part = io.read_nonblock(16_384, exception: false)
      if part == :wait_readable
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert remaining.positive? && IO.select([io], nil, nil, remaining), "#{label} did not complete"
      elsif part
        bytes << part
      else
        flunk "CLI closed before returning a complete frame"
      end
    end
  end
end
