# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require_relative "../support/tmux_fixture"
require_relative "../../gems/libtmux/lib/libtmux/endpoint"

class IdentityTest < Minitest::Test
  def test_repeated_constructor_cancellation_preserves_the_first_failure
    LibTmuxTest::TmuxFixture.open do |fixture|
      ready, cleanup_ready, release = Queue.new, Queue.new, Queue.new
      first = Interrupt.new("first binding cancellation")
      later = Interrupt.new("later cleanup cancellation")
      directory = nil
      interrupted = Class.new(LibTmux::Internal::SocketIdentity) do
        define_method(:make_route) do |source|
          super(source)
          directory = @directory
          ready << true
          Thread.handle_interrupt(Exception => :immediate) { release.pop }
        end
        define_method(:remove_route) do
          cleanup_ready << true
          release.pop
          super()
        end
      end
      worker = Thread.new do
        interrupted.new(LibTmux::Endpoint.new(socket_path: fixture.socket_path))
      rescue Exception => error
        error
      end
      assert ready.pop(timeout: 0.5), "binding did not reach its cancellation barrier"
      worker.raise(first)
      assert cleanup_ready.pop(timeout: 0.5), "binding did not start cleanup"
      worker.raise(later)
      release << true
      assert worker.join(0.5), "binding cleanup did not finish"
      assert_same first, worker.value
      refute Dir.exist?(directory)
    ensure
      release << true if release
      worker&.kill if worker&.alive?
      worker&.join(0.5)
      File.unlink(File.join(directory, "socket")) if directory && File.socket?(File.join(directory, "socket"))
      Dir.rmdir(directory) if directory && Dir.exist?(directory)
    end
  end

  def test_a_fork_cannot_use_or_retire_the_parent_binding
    LibTmuxTest::TmuxFixture.open do |fixture|
      pin = LibTmux::Internal::SocketIdentity.new(LibTmux::Endpoint.new(socket_path: fixture.socket_path))
      reader, writer = IO.pipe
      child = fork do
        reader.close
        begin
          pin.command_prefix
          writer.write("bad")
        rescue LibTmux::ClosedError
          pin.close
          writer.write("ok")
        ensure
          writer.close
        end
        exit! 0
      end
      writer.close
      assert IO.select([reader], nil, nil, 0.5), "forked binding did not settle"
      assert_equal "ok", reader.read(2)
      status = Process.wait2(child).last
      child = nil
      assert status.success?
      assert route(pin, "has-session", "-t", "fixture").last.success?
    ensure
      if child
        Process.kill("KILL", child)
        Process.waitpid(child)
      end
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      pin&.close
    end
  end

  def test_symlinked_source_binds_its_socket_but_a_non_socket_source_is_refused
    LibTmuxTest::TmuxFixture.open do |fixture|
      Dir.mktmpdir("libtmux-ruby-") do |directory|
        selector = File.join(directory, "selector")
        File.symlink(fixture.socket_path, selector)
        pin = LibTmux::Internal::SocketIdentity.new(LibTmux::Endpoint.new(socket_path: selector))
        begin
          File.unlink(selector)
          File.write(selector, "not a socket")
          assert route(pin, "has-session", "-t", "fixture").last.success?
          error = assert_raises(LibTmux::TargetNotFoundError) do
            LibTmux::Internal::SocketIdentity.new(LibTmux::Endpoint.new(socket_path: selector))
          end
          refute_includes error.message, selector
        ensure
          pin.close
        end
      end
    end
  end

  def test_constructor_interruption_removes_the_owned_route
    LibTmuxTest::TmuxFixture.open do |fixture|
      directory = nil
      interrupted = Class.new(LibTmux::Internal::SocketIdentity) do
        define_method(:make_route) do |source|
          super(source)
          directory = @directory
          raise Interrupt, "cancel binding"
        end
      end
      assert_raises(Interrupt) { interrupted.new(LibTmux::Endpoint.new(socket_path: fixture.socket_path)) }
      refute Dir.exist?(directory), "interrupted binding leaked its private directory"
    ensure
      File.unlink(File.join(directory, "socket")) if directory && File.socket?(File.join(directory, "socket"))
      Dir.rmdir(directory) if directory && Dir.exist?(directory)
    end
  end

  def test_constructor_cleanup_failure_preserves_the_original_error
    LibTmuxTest::TmuxFixture.open do |fixture|
      directory = nil
      failure = LibTmux::ProtocolError.new("original binding failure")
      failing = Class.new(LibTmux::Internal::SocketIdentity) do
        define_method(:make_route) do |source|
          super(source)
          directory = @directory
          File.write(File.join(directory, "occupied"), "owned fixture")
          raise failure
        end
      end
      observed = assert_raises(LibTmux::ProtocolError) do
        failing.new(LibTmux::Endpoint.new(socket_path: fixture.socket_path))
      end
      assert_same failure, observed
      assert_equal 1, observed.cleanup_errors.length
      refute_includes observed.cleanup_errors.first, directory
      refute File.exist?(File.join(directory, "socket"))
    ensure
      File.unlink(File.join(directory, "occupied")) if directory && File.exist?(File.join(directory, "occupied"))
      File.unlink(File.join(directory, "socket")) if directory && File.socket?(File.join(directory, "socket"))
      Dir.rmdir(directory) if directory && Dir.exist?(directory)
    end
  end

  def route(pin, *args)
    Open3.capture3({"TMUX" => nil, "TMUX_PANE" => nil}, *pin.command_prefix, *args)
  end

  def test_selector_replacement_cannot_redirect_a_bound_command
    LibTmuxTest::TmuxFixture.open do |first|
      LibTmuxTest::TmuxFixture.open do |second|
        endpoint = LibTmux::Endpoint.new(socket_path: first.socket_path)
        pin = LibTmux::Internal::SocketIdentity.new(endpoint)
        begin
          first.tmux("set-option", "-g", "@identity_test", "first")
          second.tmux("set-option", "-g", "@identity_test", "second")
          File.unlink(first.socket_path)
          File.link(second.socket_path, first.socket_path)

          stdout, stderr, status = route(pin, "show-option", "-gv", "@identity_test")
          assert status.success?, stderr
          assert_equal "first\n", stdout
          _, stderr, status = route(pin, "set-option", "-g", "@identity_test", "changed")
          assert status.success?, stderr
          assert_equal "second\n", second.tmux("show-option", "-gv", "@identity_test").first
        ensure
          pin.close
        end
        assert_raises(LibTmux::ClosedError) { pin.command_prefix }
      end
    end
  end

  def test_closing_a_binding_preserves_the_borrowed_server_and_expires_its_identity
    LibTmuxTest::TmuxFixture.open do |fixture|
      endpoint = LibTmux::Endpoint.new(socket_path: fixture.socket_path)
      first = LibTmux::Internal::SocketIdentity.new(endpoint)
      route_directory = File.dirname(first.command_prefix.last)
      original_key = first.key
      first.close
      first.close
      refute File.exist?(route_directory)
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
      second = LibTmux::Internal::SocketIdentity.new(endpoint)
      begin
        refute_equal original_key, second.key
      ensure
        second.close
      end
    end
  end

  def test_a_dead_pinned_socket_cannot_start_or_reach_a_replacement_server
    LibTmuxTest::TmuxFixture.open do |replacement|
      pin = nil
      original_path = nil
      LibTmuxTest::TmuxFixture.open do |original|
        original_path = original.socket_path
        pin = LibTmux::Internal::SocketIdentity.new(LibTmux::Endpoint.new(socket_path: original_path))
        # Keep the route outside fixture cleanup by selecting a same-filesystem directory.
        refute_equal File.dirname(original_path), File.dirname(pin.command_prefix.last)
      end
      begin
        Dir.mkdir(File.dirname(original_path), 0o700)
        File.link(replacement.socket_path, original_path)
        _, _, status = route(pin, "new-session", "-d", "-s", "must-not-start")
        refute status.success?
        refute replacement.tmux("has-session", "-t", "must-not-start").last.success?
      ensure
        pin.close
        File.unlink(original_path) if File.socket?(original_path)
        Dir.rmdir(File.dirname(original_path)) if Dir.exist?(File.dirname(original_path))
      end
    end
  end
end
