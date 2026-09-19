# frozen_string_literal: true

require "fileutils"
require "fiddle"
require "fcntl"
require "libtmux/child"
require "tmpdir"

module LibTmuxTest
  class TmuxFixture
    class Error < StandardError
      attr_reader :cleanup_errors

      def initialize(message, cleanup_errors: [])
        super(message)
        @cleanup_errors = cleanup_errors.dup.freeze
      end
    end

    module CleanupDetails
      attr_reader :fixture_cleanup_errors
    end

    class OwnedChild < LibTmux::Internal::OwnedChild
      def join(timeout)
        return super if @retiring

        wait_observed(timeout)
        observed? ? self : nil
      end

      def finish_signalling
        @retiring = true
        super
      end

      def value
        finish_signalling
        raise Error, "owned tmux process did not finish reaping" unless join(0.5)

        if observation_error && !@error_reported
          @error_reported = true
          raise observation_error
        end
        raise retirement_error if retirement_error

        status
      end
    end
    private_constant :CleanupDetails, :OwnedChild

    CLEAN_ENV = {"TMUX" => nil, "TMUX_PANE" => nil}.freeze
    DEADLINE_SECONDS = 0.5
    private_constant :CLEAN_ENV, :DEADLINE_SECONDS

    attr_reader :socket_path, :cleanup_errors, :executable

    def self.open
      fixture = error = result = nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          begin
            fixture = new
            fixture.start
            Thread.handle_interrupt(Exception => :immediate) { result = yield fixture }
          rescue Exception => failure
            error = failure
          ensure
            begin
              fixture&.close
            rescue Exception => cleanup
              fixture.send(:attach_cleanup_details, error, cleanup) if error
              error ||= cleanup
            end
          end
        end
      rescue Exception => deferred
        error ||= deferred
      end
      raise error if error

      result
    end

    def initialize(executable: ENV.fetch("LIBTMUX_TEST_TMUX", "tmux"))
      @executable = executable
      @process_wait = LibTmux::Internal::ProcessWait.new
      @directory = Dir.mktmpdir("libtmux-ruby-")
      @socket_path = File.join(@directory, "socket")
      @clients = {}
      @clients_mutex = Mutex.new
      @retirement_mutex = Mutex.new
      @closed = false
      @cleanup_complete = false
      @cleanup_errors = [].freeze
    end

    def start
      raise Error, "foreground tmux fixture currently requires Linux inotify" unless RUBY_PLATFORM.include?("linux")

      config_path = File.join(@directory, "tmux.conf")
      File.write(config_path, "set-option -g default-shell /bin/sh\n")
      watch_socket do
        # -D keeps the daemon as our child; its exit can be observed and reaped.
        @server = spawn_owned(@executable, "-D", "-S", @socket_path, "-f", config_path)
        @server.first.close
      end
      _, error, status = capture("new-session", "-d", "-s", "fixture", "-x", "80", "-y", "24", "cat")
      raise Error, "tmux could not create fixture session: #{error}" unless status.success?
    end

    def tmux(*arguments)
      capture(*arguments)
    end

    def close
      failure = nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          unless @cleanup_complete
            clients = @clients_mutex.synchronize do
              @closed = true
              @clients.dup
            end
            errors = []
            attempt_cleanup(errors, "server termination") do
              # The socket may have been replaced. Cleanup follows the owned child.
              @server.last.signal("TERM") if @server
            end
            clients.each do |pid, client|
              attempt_cleanup(errors, "client retirement") do
                retire(client)
                @clients_mutex.synchronize { @clients.delete(pid) }
              end
            end
            attempt_cleanup(errors, "server retirement") { retire(@server) } if @server
            attempt_cleanup(errors, "temporary directory removal") do
              FileUtils.remove_entry(@directory) if File.exist?(@directory)
            end
            @cleanup_errors = errors.freeze
            @cleanup_complete = errors.empty?
            failure = Error.new("tmux fixture cleanup failed", cleanup_errors: errors) unless errors.empty?
          end
        end
      rescue Exception => deferred
        failure ||= deferred
      end
      raise failure if failure

      nil
    end

    private

    def capture(*arguments)
      client = failure = result = nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          begin
            @clients_mutex.synchronize do
              raise Error, "fixture is closed" if @closed

              client = spawn_owned(@executable, "-N", "-S", @socket_path, "-f", "/dev/null", *arguments)
              @clients[client.last.pid] = client
            end
            input, output, error, waiter = client
            input.close
            Thread.handle_interrupt(Exception => :immediate) do
              deadline = monotonic + DEADLINE_SECONDS
              buffers = {output => +"".b, error => +"".b}
              reading = buffers.keys
              until reading.empty?
                wait_readable(reading, deadline).each do |io|
                  bytes = io.read_nonblock(16_384, exception: false)
                  case bytes
                  when nil then reading.delete(io)
                  when String then buffers.fetch(io) << bytes
                  end
                end
              end
              remaining = deadline - monotonic
              raise Error, "tmux client exceeded fixture deadline" unless remaining.positive? && waiter.join(remaining)

              result = [buffers.fetch(output), buffers.fetch(error), waiter.value]
            end
          rescue Exception => error
            failure = error
          ensure
            if client
              begin
                retire(client)
                @clients_mutex.synchronize { @clients.delete(client.last.pid) }
              rescue Exception => cleanup
                attach_cleanup_details(failure, cleanup) if failure
                failure ||= cleanup
              end
            end
          end
        end
      rescue Exception => deferred
        failure ||= deferred
      end
      raise failure if failure

      result
    end

    def spawn_owned(*arguments)
      streams = []
      observer = OwnedChild.new(@process_wait)
      begin
        child_input, input = IO.pipe.tap { |pair| streams.concat(pair) }
        output, child_output = IO.pipe.tap { |pair| streams.concat(pair) }
        error, child_error = IO.pipe.tap { |pair| streams.concat(pair) }
        streams.each(&:binmode)
        pid = Process.spawn(CLEAN_ENV, *arguments, in: child_input, out: child_output,
          err: child_error, close_others: true)
        observer.spawned(pid)
        [child_input, child_output, child_error].each(&:close)
        [input, output, error, observer]
      rescue Exception => failure
        observer.spawned(nil) unless observer.pid
        errors = []
        streams.each { |io| attempt_cleanup(errors, "pipe close") { io.close unless io.closed? } }
        attempt_cleanup(errors, "failed spawn retirement") do
          begin
            observer.signal("KILL")
          ensure
            observer.finish_signalling
          end
          raise Error, "failed spawn observer did not finish" unless observer.join(0.5)

          observer.value if observer.pid
        ensure
          observer.close
        end
        attach_cleanup_details(failure, Error.new("spawn cleanup failed", cleanup_errors: errors)) unless errors.empty?
        raise failure
      end
    end

    def watch_socket
      libc = Fiddle::Handle::DEFAULT
      initialize_watch = Fiddle::Function.new(libc["inotify_init1"], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      add_watch = Fiddle::Function.new(libc["inotify_add_watch"],
        [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      fd = initialize_watch.call(Fcntl::O_NONBLOCK)
      raise SystemCallError.new("inotify_init1", Fiddle.last_error) if fd.negative?

      events = IO.for_fd(fd, autoclose: true)
      begin
        events.close_on_exec = true
        watch = add_watch.call(fd, @directory, 0x00000004) # IN_ATTRIB
        raise SystemCallError.new("inotify_add_watch", Fiddle.last_error) if watch.negative?

        yield
        deadline = monotonic + DEADLINE_SECONDS
        loop do
          wait_readable([events], deadline)
          bytes = events.read_nonblock(4096, exception: false)
          next unless bytes.is_a?(String)

          offset = 0
          while offset < bytes.bytesize
            descriptor, mask, _, size = bytes.byteslice(offset, 16).unpack("iIII")
            name = bytes.byteslice(offset + 16, size).delete("\0")
            # tmux chmods the socket after bind/listen, before accepting clients.
            return if descriptor == watch && mask & 0x00000004 != 0 && name == "socket"

            raise Error, "fixture filesystem event queue overflowed" if mask & 0x00004000 != 0

            offset += 16 + size
          end
        end
      ensure
        events.close
      end
    end

    def wait_readable(streams, deadline)
      remaining = deadline - monotonic
      ready = IO.select(streams, nil, nil, remaining) if remaining.positive?
      raise Error, "tmux fixture exceeded event deadline" unless ready

      ready.first
    end

    def retire(process)
      @retirement_mutex.synchronize do
        *streams, waiter = process
        errors = []
        streams.each do |io|
          attempt_cleanup(errors, "pipe close") { io.close unless io.closed? }
        end
        attempt_cleanup(errors, "child retirement") do
          begin
            waiter.signal("KILL") unless waiter.join(0.1)
          ensure
            waiter.finish_signalling
          end
          raise Error, "owned tmux process did not exit" unless waiter.join(0.5)
          waiter.value
        ensure
          waiter.close
        end
        raise Error.new("owned process cleanup failed", cleanup_errors: errors) unless errors.empty?
      end
    end

    def attempt_cleanup(errors, operation)
      yield
    rescue Exception => error
      errors << "#{operation} failed (#{error.class})"
      errors.concat(error.cleanup_errors) if error.is_a?(Error)
    end

    def attach_cleanup_details(error, cleanup)
      return if error.frozen?

      previous = error.respond_to?(:fixture_cleanup_errors) ? error.fixture_cleanup_errors : []
      details = cleanup.is_a?(Error) ? cleanup.cleanup_errors : ["fixture cleanup failed (#{cleanup.class})"]
      error.extend(CleanupDetails)
      error.instance_variable_set(:@fixture_cleanup_errors, (previous + details).freeze)
    rescue StandardError
      # A caller may supply an exception that cannot accept diagnostic metadata.
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
