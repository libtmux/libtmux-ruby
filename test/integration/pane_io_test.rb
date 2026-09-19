# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "socket"
require "shellwords"

class PaneIOTest < Minitest::Test
  def test_literal_input_paste_separator_and_brackets_reach_the_pane
    with_pane do |server, pane, channel, _directory|
      text = "C-a; #{'#{pane_id}'} 雪\nnext"
      assert pane.send_text("").success?
      assert pane.send_text(text).success?
      assert_equal text.b, receive_input(channel, text.bytesize)
      assert pane.send_keys("C-a", "Enter").success?
      assert_equal "\x01\r".b, receive_input(channel, 2)

      server.write_buffer(name: "paste", data: "first\n雪\n")
      assert pane.paste(buffer: "paste").success?
      assert_equal "first\r雪\r".b, receive_input(channel, "first\r雪\r".bytesize)
      assert pane.paste(buffer: "paste", separator: "::", bracketed: true).success?
      assert_equal "first::雪::".b, receive_input(channel, "first::雪::".bytesize)

      render(channel, "\e[?2004h")
      assert pane.paste(buffer: "paste", separator: "\n", bracketed: true, delete: true).success?
      expected = "\e[200~first\n雪\n\e[201~".b
      assert_equal expected, receive_input(channel, expected.bytesize)
      assert_empty server.list_buffers
    end
  end

  def test_pipe_directions_preserve_bytes_and_toggle_closes_the_previous_pipe
    with_pane do |_server, pane, channel, directory|
      listener = UNIXServer.new(File.join(directory, "pipe"))
      pipe_reader = nil
      begin
        script = 'UNIXSocket.open(ARGV.fetch(0)) { |io| io.write(ARGV.fetch(1) + "\n"); IO.copy_stream(STDIN, io) }'
        command = [Gem.ruby, "--disable=rubyopt,gems", "-rsocket", "-e", script, listener.path].shelljoin + " '\#{pane_id}'"
        assert pane.pipe(shell_command: command, timeout: 0.5).success?
        assert IO.select([listener], nil, nil, 0.5), "pipe process did not connect"
        pipe_reader = listener.accept
        assert_equal "#{pane.id}\n".b, read_bytes(pipe_reader, pane.id.bytesize + 1)
        assert_equal "1\n", pane.display('#{pane_pipe}').text
        payload = "NUL\0\xff\n".b
        render(channel, payload)
        assert_equal payload + "\e[6n", read_bytes(pipe_reader, payload.bytesize + 4)

        assert pane.pipe(shell_command: command, only_if_closed: true, timeout: 0.5).success?
        assert_equal "0\n", pane.display('#{pane_pipe}').text
        assert IO.select([pipe_reader], nil, nil, 0.5), "closed pipe did not reach EOF"
        assert_nil pipe_reader.read(1)
        assert_equal :wait_readable, listener.accept_nonblock(exception: false)

        input = "input\0\xff\n".b
        writer = [Gem.ruby, "--disable=rubyopt,gems", "-e", 'STDOUT.write([ARGV.fetch(0)].pack("H*"))', input.unpack1("H*")].shelljoin
        assert pane.pipe(shell_command: writer, input: true, output: false, timeout: 0.5).success?
        assert_equal input, receive_input(channel, input.bytesize)

        duplex = [Gem.ruby, "--disable=rubyopt,gems", "-e", 'STDOUT.sync = true; while (bytes = STDIN.readpartial(1024)); STDOUT.write(bytes); end'].shelljoin
        assert pane.pipe(shell_command: duplex, input: true, output: true, timeout: 0.5).success?
        channel.write("O" + [payload.bytesize].pack("N") + payload)
        assert_equal payload, receive_input(channel, payload.bytesize)
        assert pane.pipe(timeout: 0.5).success?
        assert_equal "0\n", pane.display('#{pane_pipe}').text
      ensure
        pipe_reader&.close
        listener.close
      end
    end
  end

  private

  def with_pane
    LibTmuxTest::TmuxFixture.open do |fixture|
      directory = File.dirname(fixture.socket_path)
      listener = UNIXServer.new(File.join(directory, "io"))
      channel = nil
      begin
        LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
          window = server.list_sessions.first.new_window(name: "io", command: program(listener.path))
          pane = window.list_panes.first
          assert IO.select([listener], nil, nil, 0.5), "pane program did not connect"
          channel = listener.accept
          yield server, pane, channel, directory
        end
      ensure
        channel&.close
        listener.close
      end
    end
  end

  def program(path)
    source = <<~'RUBY'
      abort "stty failed" unless system("stty", "raw", "-echo")
      STDOUT.sync = true
      UNIXSocket.open(ARGV.fetch(0)) do |channel|
        while (operation = channel.read(1))
          length = channel.read(4).unpack1("N")
          if operation == "I"
            channel.write(STDIN.read(length))
          else
            STDOUT.write(channel.read(length))
            next unless operation == "R"

            STDOUT.write("\e[6n")
            response = +""
            response << STDIN.read(1) until response.end_with?("R")
            channel.write("R")
          end
        end
      end
    RUBY
    [Gem.ruby, "--disable=rubyopt,gems", "-rsocket", "-e", source, path]
  end

  def receive_input(channel, size)
    channel.write("I" + [size].pack("N"))
    read_bytes(channel, size)
  end

  def render(channel, bytes)
    channel.write("R" + [bytes.bytesize].pack("N") + bytes)
    assert_equal "R", read_bytes(channel, 1)
  end

  def read_bytes(io, size)
    data = +"".b
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    while data.bytesize < size
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert remaining.positive? && IO.select([io], nil, nil, remaining), "pane I/O did not arrive"
      bytes = io.read_nonblock(size - data.bytesize, exception: false)
      next if bytes == :wait_readable

      refute_nil bytes, "pane I/O ended early"
      data << bytes
    end
    data
  end
end
