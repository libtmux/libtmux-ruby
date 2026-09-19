# frozen_string_literal: true

require "fiddle"
require "socket"

module LibTmux
  module MCP
    # Descriptors observe borrowed processes; this class never signals or reaps.
    class ProcessIdentity
      PEER_PIDFD = 77 # Linux asm-generic/socket.h, available since Linux 6.6.
      private_constant :PEER_PIDFD
      module CleanupDetails
        attr_reader :mcp_cleanup_errors
      end

      def self.attach_cleanup(failure, errors)
        if failure.is_a?(LibTmux::Error)
          failure.__send__(:attach_cleanup_errors, errors)
        else
          failure.extend(CleanupDetails)
          failure.instance_variable_set(:@mcp_cleanup_errors, ((failure.mcp_cleanup_errors || []) + errors).freeze)
        end
      end

      class Resources
        def initialize(*ios)
          @ios = ios
        end

        def add(io)
          @ios << io
          io
        end

        def release(*ios)
          @ios -= ios
        end

        def empty?
          @ios.empty?
        end

        def close
          errors = []
          @ios.dup.each do |io|
            begin
              io.close unless io.closed?
            rescue Exception => error
              errors << "native observer close failed (#{error.class})"
            ensure
              @ios.delete(io) if io.closed?
            end
          end
          raise TransportError.new("native observer cleanup failed", phase: :retire, cleanup_errors: errors) unless errors.empty?

          nil
        end
      end

      attr_reader :io, :peer, :generation, :pid

      def self.native(name, arguments, result)
        unless /\A(?:x86_64|aarch64)-linux/.match?(RUBY_PLATFORM) && Fiddle::SIZEOF_LONG == 8
          raise UnsupportedFeatureError.new("process cursors require Linux x86_64 or aarch64", phase: :admission)
        end
        Fiddle::Function.new(Fiddle::Handle::DEFAULT[name], arguments, result)
      rescue Fiddle::DLError
        raise UnsupportedFeatureError.new("native process cursor support is unavailable", phase: :admission), cause: nil
      end

      def self.readable?(io)
        poll = native("poll", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        data = [io.fileno, 1, 0].pack("iss")
        result = poll.call(data, 1, 0)
        raise TransportError.new("process descriptor observation failed", phase: :read) if result.negative?

        !result.zero?
      end

      def self.procfs_namespace
        File.open("/proc/self/status") do |status|
          buffer = "\0" * 256
          statfs = native("fstatfs", [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
          valid = statfs.call(status.fileno, buffer).zero? && buffer.unpack1("l!") == 0x9fa0
          rows = status.read(65_537).lines.grep(/^NSpid:/)
          valid &&= rows.length == 1 && rows.first.split.drop(1) == [Process.pid.to_s]
          raise UnsupportedFeatureError.new("process cursors require procfs in the caller PID namespace", phase: :admission) unless valid
        end
        File.open("/proc/self/ns/pid")
      rescue SystemCallError, IOError
        raise UnsupportedFeatureError.new("process namespace evidence is unavailable", phase: :admission), cause: nil
      end

      def self.acquire(server, server_pid:, pane_pid:, budget:, on_retire: nil)
        resources = Resources.new
        failure = identity = nil
        begin
          own_namespace = resources.add(procfs_namespace)
          route = server.__send__(:with_bound_endpoint) { |_endpoint, pin| pin.command_prefix.last }
          socket = resources.add(Socket.new(Socket::AF_UNIX, Socket::SOCK_STREAM, 0))
          address = Socket.sockaddr_un(route)
          loop do
            remaining = budget.options.fetch(:timeout)
            connected = socket.connect_nonblock(address, exception: false)
            break unless connected == :wait_writable

            Fiber.scheduler.io_wait(socket, IO::WRITABLE, remaining)
          rescue Errno::EISCONN
            break
          end
          # SO_PEERPIDFD avoids reacquiring a potentially reused SO_PEERCRED PID.
          peer = resources.add(IO.for_fd(socket.getsockopt(Socket::SOL_SOCKET, PEER_PIDFD).int))
          peer.close_on_exec = true
          peer_pid = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).data.unpack1("i")
          unless peer_pid == server_pid && !readable?(peer)
            raise UnsupportedFeatureError.new("socket peer identity does not establish the tmux process", phase: :admission)
          end
          other_namespace = resources.add(File.open("/proc/#{peer_pid}/ns/pid"))
          same_namespace = [own_namespace.stat.dev, own_namespace.stat.ino] == [other_namespace.stat.dev, other_namespace.stat.ino]
          unless same_namespace && !readable?(peer)
            raise UnsupportedFeatureError.new("tmux and observer PID namespaces differ", phase: :admission)
          end
          opener = native("pidfd_open", [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
          descriptor = opener.call(pane_pid, 0)
          if descriptor.negative?
            error = Fiddle.last_error
            if [Errno::EMFILE::Errno, Errno::ENFILE::Errno].include?(error)
              raise CapacityError.new("process descriptor capacity exhausted", phase: :admission)
            elsif error == Errno::ESRCH::Errno
              raise TargetNotFoundError.new("pane process is unavailable", phase: :admission)
            end
            raise UnsupportedFeatureError.new("pane process identity is unavailable", phase: :admission)
          end

          pane = resources.add(IO.for_fd(descriptor))
          pane.close_on_exec = true
          identity = new(pane, peer, pane_pid)
          resources.release(pane, peer)
          identity.ensure_live!
        rescue Errno::ENOPROTOOPT, Errno::EINVAL, Errno::EPERM, Errno::EACCES, Errno::ENOENT
          failure = UnsupportedFeatureError.new("peer process identity is unavailable", phase: :admission)
        rescue Exception => error
          failure = error
        ensure
          begin
            resources.close
          rescue TransportError => cleanup
            on_retire&.call(resources) unless resources.empty?
            attach_cleanup(failure, cleanup.cleanup_errors) if failure
            failure ||= cleanup
          end
          if failure && identity
            begin
              identity.close
            rescue TransportError => cleanup
              on_retire&.call(identity)
              attach_cleanup(failure, cleanup.cleanup_errors)
            end
          end
        end
        raise failure, cause: nil if failure

        identity
      end

      def initialize(io, peer, pid)
        @io, @peer, @pid = io, peer, pid
        @generation = SecureRandom.hex(16).freeze
        @references = 1
        @resources = Resources.new(io, peer)
      end
      private_class_method :new

      def retain
        raise ClosedError.new("process cursor is closed", phase: :admission) if @references.zero?

        @references += 1
        self
      end

      def close
        @references -= 1 if @references.positive?
        @resources.close if @references.zero?
        nil
      end

      def peer_alive!
        if @references.zero? || self.class.readable?(@peer)
          raise TargetNotFoundError.new("retained tmux process is unavailable", phase: :read, delivery: :observed)
        end
      end

      def exited?
        peer_alive!
        self.class.readable?(@io)
      end

      def ensure_live!
        raise TargetNotFoundError.new("retained pane process exited", phase: :read, delivery: :observed) if exited?
      end
    end
    private_constant :ProcessIdentity
  end
end
