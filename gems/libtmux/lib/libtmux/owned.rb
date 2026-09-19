# frozen_string_literal: true

require "fcntl"
require "libtmux/server"
require "libtmux/child"

module LibTmux
  class Server
    # Starts a foreground daemon on a new private endpoint. Close owns its exit.
    # No session is created; the default config is empty. Startup blocks.
    def self.start(**options, &block)
      Internal.const_get(:OwnedServer, false).open(**options, &block)
    end

    def owned?
      false
    end
  end

  module Internal
    class SocketReadiness
      attr_reader :reader

      def initialize(directory)
        unless RUBY_PLATFORM.include?("linux")
          raise UnsupportedFeatureError.new("owned daemon readiness currently requires Linux inotify", phase: :startup)
        end
        libc = Fiddle::Handle::DEFAULT
        init = Fiddle::Function.new(libc["inotify_init1"], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        add = Fiddle::Function.new(libc["inotify_add_watch"],
          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        fd = init.call(Fcntl::O_NONBLOCK)
        raise SystemCallError.new("inotify_init1", Fiddle.last_error) if fd.negative?

        @reader = IO.for_fd(fd, autoclose: true)
        @reader.close_on_exec = true
        @watch = add.call(fd, directory, 0x00000004) # IN_ATTRIB
        raise SystemCallError.new("inotify_add_watch", Fiddle.last_error) if @watch.negative?
      rescue Exception
        close
        raise
      end

      def ready?(pid)
        bytes = @reader.read_nonblock(16_384, exception: false)
        return false unless bytes.is_a?(String)

        offset = 0
        found = false
        while offset < bytes.bytesize
          header = bytes.byteslice(offset, 16)
          raise ProtocolError.new("truncated socket readiness event", phase: :startup, pid: pid, delivery: :possibly_sent) unless header.bytesize == 16

          descriptor, mask, _, size = header.unpack("iIII")
          if mask & 0x00004000 != 0 # IN_Q_OVERFLOW
            raise CapacityError.new("socket readiness events overflowed", phase: :startup, pid: pid, delivery: :possibly_sent)
          end
          name = bytes.byteslice(offset + 16, size)
          raise ProtocolError.new("truncated socket readiness name", phase: :startup, pid: pid, delivery: :possibly_sent) unless name && name.bytesize == size

          # tmux's initial chmod follows bind/listen; no client can cause it yet.
          found ||= descriptor == @watch && mask & 0x00000004 != 0 && name.delete("\0") == "socket"
          offset += 16 + size
        end
        found
      end

      def close
        @reader.close if @reader && !@reader.closed?
      end
    end

    class OwnedDaemon
      attr_reader :endpoint

      def initialize(executable:, config:, timeout:, cancel:)
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
          raise ArgumentError, "startup timeout must be positive and finite"
        end
        if cancel && (!cancel.respond_to?(:reader) || !cancel.respond_to?(:cancelled?))
          raise ArgumentError, "cancel must provide a cancellation reader and state"
        end
        if config && (!config.is_a?(String) || config.empty? || config.include?("\0"))
          raise ArgumentError, "config must be a nonempty filename without NUL"
        end
        config = config ? File.expand_path(config) : File::NULL
        raise ArgumentError, "config must be a readable regular file" unless File.file?(config) && File.readable?(config) || config == File::NULL

        @owner_pid = Process.pid
        @mutex = Mutex.new
        @closed = false
        failure = nil
        deadline = clock + timeout
        begin
          Thread.handle_interrupt(Exception => :never) do
            begin
              check_cancel(cancel)
              @directory = Dir.mktmpdir("libtmux-ruby-server-")
              @endpoint = Endpoint.new(socket_path: File.join(@directory, "socket"), executable: executable)
              if @endpoint.socket_path.bytesize > 103
                raise UnsupportedFeatureError.new("owned Unix socket path exceeds the platform limit", phase: :startup)
              end
              @readiness = SocketReadiness.new(@directory)
              @child = OwnedChild.new
              pid = nil
              begin
                check_cancel(cancel)
                check_deadline(deadline)
                pid = Process.spawn({"TMUX" => nil, "TMUX_PANE" => nil},
                  @endpoint.executable, "-u", "-D", "-S", @endpoint.socket_path, "-f", config,
                  in: File::NULL, out: File::NULL, err: File::NULL, close_others: true)
              rescue SystemCallError, IOError => error
                raise TransportError.new("owned daemon could not start (#{error.class})", phase: :spawn), cause: nil
              ensure
                @child.spawned(pid)
              end
              Thread.handle_interrupt(Exception => :immediate) { await_ready(deadline, cancel) }
              @readiness.close
            rescue Exception => error
              failure = error
              begin
                close
              rescue Exception => cleanup
                attach_cleanup(failure, cleanup)
              end
            end
          end
        rescue Exception => deferred
          failure ||= deferred
        end
        if failure
          begin
            Thread.handle_interrupt(Exception => :never) { close }
          rescue Exception => cleanup
            attach_cleanup(failure, cleanup)
          end
          raise failure
        end
      end

      def close
        if Process.pid != @owner_pid
          @child&.detach
          @readiness&.close
          return nil
        end
        Thread.handle_interrupt(Exception => :never) do
          @mutex.synchronize do
            return nil if @closed

            errors = []
            deadline = clock + 0.5
            attempt(errors, "readiness close") { @readiness&.close }
            if @child
              attempt(errors, "daemon retirement") do
                begin
                  unless @child.observed? || @child.complete?
                    @child.signal("TERM")
                    @child.wait_observed([0.05, deadline - clock].min.clamp(0, 0.05))
                    @child.signal("KILL") unless @child.observed? || @child.complete?
                  end
                ensure
                  @child.finish_signalling
                end
                unless @child.join((deadline - clock).clamp(0, 0.5))
                  raise DeadlineExceeded.new("owned daemon has not retired; retry close", phase: :retire, pid: @child.pid)
                end
              end
              attempt(errors, "observer close") { @child.close } if @child.complete?
            end
            if !@child || @child.complete?
              attempt(errors, "socket removal") do
                File.unlink(@endpoint.socket_path) if @endpoint && File.exist?(@endpoint.socket_path)
              end
              attempt(errors, "owned directory removal") do
                Dir.rmdir(@directory) if @directory && File.exist?(@directory)
              end
            end
            @closed = errors.empty?
            if @child&.complete? && !@observer_fault_reported
              [@child.retirement_error, @child.observation_error].compact.each do |error|
                errors << "owned child observation or retirement failed (#{error.class})"
              end
              @observer_fault_reported = true
            end
            unless errors.empty?
              raise TransportError.new("owned daemon cleanup failed", phase: :retire,
                pid: @child&.pid, delivery: @child&.pid ? :possibly_sent : :not_sent, cleanup_errors: errors)
            end
          end
        end
        nil
      end

      private

      def await_ready(deadline, cancel)
        loop do
          if @child.observed? || @child.observation_error || @child.complete?
            raise TransportError.new("owned tmux daemon exited before becoming ready", phase: :startup,
              pid: @child.pid, delivery: :possibly_sent)
          end
          return if @readiness.ready?(@child.pid)

          check_cancel(cancel)
          check_deadline(deadline)
          readers = [@readiness.reader, @child.reader]
          readers << cancel.reader if cancel
          IO.select(readers, nil, nil, [deadline - clock, 0].max)
        end
      rescue IOError, SystemCallError
        raise TransportError.new("owned daemon readiness failed", phase: :startup,
          pid: @child.pid, delivery: :possibly_sent), cause: nil
      end

      def check_cancel(cancel)
        return unless cancel&.cancelled?

        raise Cancelled.new("owned daemon startup cancelled", phase: :startup,
          delivery: @child&.pid ? :possibly_sent : :not_sent, pid: @child&.pid)
      end

      def check_deadline(deadline)
        return if clock < deadline

        raise DeadlineExceeded.new("owned daemon startup exceeded deadline", phase: :startup,
          delivery: @child&.pid ? :possibly_sent : :not_sent, pid: @child&.pid)
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def attempt(errors, operation)
        yield
      rescue Exception => error
        errors << "#{operation} failed (#{error.class})"
        errors.concat(error.cleanup_errors) if error.is_a?(Error)
      end

      def attach_cleanup(failure, cleanup)
        if failure.is_a?(Error)
          failure.__send__(:attach_cleanup_errors, ["owned daemon close failed (#{cleanup.class})"])
        end
      end
    end

    class OwnedServer < Server
      def initialize(executable: "tmux", config: nil, timeout: 5.0, cancel: nil, **options)
        begin
          Thread.handle_interrupt(Exception => :never) do
            @daemon = OwnedDaemon.new(executable: executable, config: config, timeout: timeout, cancel: cancel)
            super(endpoint: @daemon.endpoint, **options)
            @binding_ready = true
            Thread.handle_interrupt(Exception => :immediate) { nil }
          end
        rescue Exception => failure
          begin
            Thread.handle_interrupt(Exception => :never) { close }
          rescue Exception => cleanup
            failure.__send__(:attach_cleanup_errors, ["owned daemon close failed (#{cleanup.class})"]) if failure.is_a?(Error)
          end
          raise failure
        end
      end

      def owned?
        true
      end

      def close
        failure = nil
        begin
          Thread.handle_interrupt(Exception => :never) do
            begin
              super if @binding_ready
            rescue Exception => error
              failure = error
            ensure
              begin
                @daemon&.close
              rescue Exception => cleanup
                failure.__send__(:attach_cleanup_errors, ["owned daemon close failed (#{cleanup.class})"]) if failure.is_a?(Error)
                failure ||= cleanup
              end
            end
          end
        rescue Exception => deferred
          failure ||= deferred
        end
        raise failure if failure

        nil
      end
    end
    private_constant :SocketReadiness, :OwnedDaemon, :OwnedServer
  end
end
