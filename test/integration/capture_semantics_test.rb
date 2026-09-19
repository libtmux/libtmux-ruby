# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "socket"

class CaptureSemanticsTest < Minitest::Test
  # A protocol fixture for an older advertised usage; it is not an older binary.
  class LimitedCaptureServer < LibTmux::Server
    attr_reader :capture_calls

    def run(argv, **options)
      @capture_calls = (@capture_calls || 0) + 1 if argv.first == "capture-pane"
      result = super
      return result unless argv.first == "list-commands" && argv.last == "capture-pane"

      name, usage = LibTmux::Internal::Metadata.decode(result.stdout, fields: 2).first
      usage = usage.delete("MT")
      LibTmux::CommandResult.new(stdout: "#{name.bytesize}:#{name}#{usage.bytesize}:#{usage}\n",
        stderr: result.stderr, status: result.status, elapsed_seconds: result.elapsed_seconds,
        pid: result.pid, argv: result.argv)
    end
  end

  def test_capture_preserves_requested_screen_content_and_distinguishes_mode_and_alternate_screens
    LibTmuxTest::TmuxFixture.open do |fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "screen"))
      channel = nil
      begin
        LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
          session = server.new_session(name: "screens", command: screen_program(listener.path), width: 20, height: 8)
          window = session.list_windows.first
          window.resize(width: 20, height: 8)
          pane = window.list_panes.first
          assert_equal "20:8\n", pane.display('#{pane_width}:#{pane_height}').text
          usage = server.run(["list-commands", "-F", '#{command_list_usage}', "capture-pane"]).text
          flags = usage.scan(/\[-([A-Za-z]+)(?:\]|\s)/).flatten.join
          assert IO.select([listener], nil, nil, 0.5), "screen program did not connect"
          channel = listener.accept
          render(channel, "zero\r\n\e[31mRED\e[0m  \r\nabcdefghijklmnopqrstUV\r\ntail\r\n")
          assert_equal "zero\nRED\nabcdefghijklmnopqrst\nUV\ntail\n", pane.capture(start: 0, finish: 4).stdout
          joined = pane.capture(start: 2, finish: 3, join: true).stdout
          assert_match(/\AabcdefghijklmnopqrstUV *\n\z/, joined)
          physical = pane.capture(start: 2, finish: 3, preserve_trailing: true,
            trim_trailing: flags.include?("T")).stdout.lines.map(&:chomp)
          assert_equal physical.join + "\n", pane.capture(start: 2, finish: 3, join: true, preserve_trailing: true).stdout
          if flags.include?("T")
            assert_equal "RED  \n", pane.capture(start: 1, finish: 1, preserve_trailing: true, trim_trailing: true).stdout
          else
            assert_raises(LibTmux::UnsupportedFeatureError) { pane.capture(trim_trailing: true) }
            assert_equal "RED  ", pane.capture(start: 1, finish: 1, preserve_trailing: true).stdout.byteslice(0, 5)
          end
          assert_includes pane.capture(start: 1, finish: 1, escapes: true).stdout, "\e[31mRED"
          assert_includes pane.capture(start: 1, finish: 1, escapes: true, escape_bytes: true).stdout, '\033[31mRED'
          assert_raises(LibTmux::CommandError) { pane.capture(alternate: true) }

          pane.copy_mode
          render(channel, "\e[HCHANGED")
          ordinary = pane.capture.stdout
          if flags.include?("M")
            mode = pane.capture(mode_screen: true).stdout
            refute_equal ordinary, mode
            assert_equal "zero\n", mode.lines.first
          else
            assert_raises(LibTmux::UnsupportedFeatureError) { pane.capture(mode_screen: true) }
          end
          assert_equal "CHANGED\n", ordinary.lines.first
          pane.copy_mode(cancel_mode: true)
          assert_equal ordinary, pane.capture(mode_screen: true).stdout if flags.include?("M")

          render(channel, "\e[?1049h\e[HALTERNATE")
          assert_equal "ALTERNATE\n", pane.capture(start: 0, finish: 0).stdout
          assert_equal "CHANGED\n", pane.capture(start: 0, finish: 0, alternate: true).stdout
          render(channel, "\e[?1049l")
          assert_equal "CHANGED\n", pane.capture(start: 0, finish: 0).stdout
          assert_raises(LibTmux::CommandError) { pane.capture(alternate: true) }
          server.open_control(session: session.ref) do |control|
            control.exchange("display-message -p ready", timeout: 0.5)
            events = control.subscribe(pane_id: pane.id)
            pending = "\e[31"
            channel.write([pending.bytesize | 0x80000000].pack("N") + pending)
            output = +"".b
            until output.include?(pending)
              event = events.next(timeout: 0.5)
              output << event.data if event.kind == :output
            end
            assert_equal "#{pending}\n", pane.capture(pending: true).stdout
            assert_equal "\\033[31\n", pane.capture(pending: true, escape_bytes: true).stdout
          end
        end
      ensure
        channel&.close
        listener.close
      end
    end
  end

  def test_unadvertised_capture_modes_refuse_before_capture_and_conflicting_screens_refuse
    LibTmuxTest::TmuxFixture.open do |fixture|
      LimitedCaptureServer.open(socket_path: fixture.socket_path) do |server|
        pane = server.list_panes.first
        [:mode_screen, :trim_trailing].each do |option|
          error = assert_raises(LibTmux::UnsupportedFeatureError) { pane.capture(**{option => true}) }
          assert_equal :not_sent, error.delivery
        end
        assert_nil server.capture_calls
        assert_raises(ArgumentError) { pane.capture(mode_screen: true, alternate: true) }
        assert_raises(ArgumentError) { pane.capture(pending: true, alternate: true) }
        assert pane.capture.success?
        assert_equal 1, server.capture_calls
      end
    end
  end

  private

  def screen_program(path)
    source = <<~'RUBY'
      abort "stty failed" unless system("stty", "raw", "-echo")
      STDOUT.sync = true
      UNIXSocket.open(ARGV.fetch(0)) do |channel|
        while (header = channel.read(4)) && header.bytesize == 4
          length = header.unpack1("N")
          STDOUT.write(channel.read(length & 0x7fffffff))
          next unless (length & 0x80000000).zero?

          STDOUT.write("\e[6n")
          response = +""
          response << STDIN.read(1) until response.end_with?("R")
          channel.write("R")
        end
      end
    RUBY
    [Gem.ruby, "--disable=rubyopt,gems", "-rsocket", "-e", source, path]
  end

  def render(channel, content)
    channel.write([content.bytesize].pack("N") + content)
    assert IO.select([channel], nil, nil, 0.5), "tmux did not acknowledge the rendered screen"
    assert_equal "R", channel.read(1)
  end
end
