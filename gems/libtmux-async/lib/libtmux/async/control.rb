# frozen_string_literal: true

require "libtmux/control"
require "libtmux/async/process"

module LibTmux
  module Async
    class ControlSubscription < LibTmux::ControlSubscription
      class Notification < ::Async::Notification
        alias broadcast signal
      end
      private_constant :Notification

      def initialize(scope:, **options)
        super(**options)
        @scope = scope
        @changed = Notification.new
      end

      def next(timeout: nil)
        ensure_owner
        unless timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0)
          raise ArgumentError, "timeout must be finite and nonnegative"
        end
        deadline = timeout && clock + timeout
        loop do
          @mutex.synchronize do
            if @gap
              gap, @gap = @gap, nil
              return gap
            end
            unless @queue.empty?
              event = @queue.shift
              @bytes -= event.bytesize
              return event
            end
            raise @failure if @failure
            raise StopIteration if @closed
          end
          remaining = deadline && deadline - clock
          raise DeadlineExceeded.new("control event deadline elapsed", phase: :subscription) if remaining && remaining <= 0

          if remaining
            ::Async::Task.current.with_timeout(remaining) { @changed.wait }
          else
            @changed.wait
          end
        rescue ::Async::TimeoutError
          raise DeadlineExceeded.new("control event deadline elapsed", phase: :subscription)
        end
      end

      private

      def ensure_owner
        @scope.__send__(:ensure_owner)
      end
    end

    class ControlConnection < LibTmux::ControlConnection
      def initialize(scope:, binding:, session_id:, reconnect: nil, **limits)
        @scope = scope
        @writer_changed = ::Async::Notification.new
        @startup_changed = ::Async::Notification.new
        @exchanges, @exchange_changed = {}, ::Async::Notification.new
        initialize_state(binding_key: binding.key, session_id: session_id, reconnect: reconnect, **limits)
        @driver = ControlDriver.new(self, scope, binding.command_prefix + ["-C", "attach-session", "-t", session_id])
        @worker = ::Async::Task.new(scope.__send__(:parent)) { @driver.call }
      end

      def exchange_request(line, timeout:, cancel:, flow: nil)
        ensure_owner
        unless line.is_a?(String) && !line.empty? && !line.b.match?(/[\x00\r\n]/n)
          raise ArgumentError, "control input must be one nonempty raw command line without NUL or line endings"
        end
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
          raise ArgumentError, "control timeout must be positive and finite"
        end
        if cancel && (!cancel.respond_to?(:reader) || !cancel.respond_to?(:cancelled?))
          raise ArgumentError, "cancel must provide a reader and cancellation state"
        end
        raise CapacityError.new("control command exceeds its byte limit", phase: :admission) if line.bytesize > @max_command

        deadline = clock + timeout
        request = admit(line, cancel, flow: flow)
        @exchanges[request.id] = true
        watcher = failure = nil
        begin
          if cancel
            watcher = ::Async::Task.new(::Async::Task.current) do
              begin
                Fiber.scheduler.io_wait(cancel.reader, IO::READABLE) unless cancel.cancelled?
                abort_request(request, Cancelled, "control request cancelled") if cancel.cancelled?
              rescue ::Async::Cancel
                nil
              rescue IOError, SystemCallError
                abort_request(request, TransportError, "control cancellation reader failed")
              end
            end
            watcher.run
          end
          loop do
            break if request.result || request.error
            if cancel&.cancelled?
              abort_request(request, Cancelled, "control request cancelled")
              next
            end
            remaining = deadline - clock
            unless remaining.positive?
              abort_request(request, DeadlineExceeded, "control request deadline elapsed")
              next
            end
            Fiber.scheduler.io_wait(request.reader, IO::READABLE, remaining)
          end
        rescue Exception => error
          failure = error unless error.is_a?(::Async::Cancel)
          abort_request(request, Cancelled, "control request interrupted") unless request.result
        ensure
          errors = []
          if watcher
            begin
              watcher.cancel unless watcher.finished?
            rescue ::Async::Cancel
              retry
            end
            @scope.__send__(:join_task, watcher, clock + 0.4, errors)
          end
          begin
            abort_request(request, Cancelled, "control request interrupted")
          ensure
            [request.reader, request.writer].each { |io| io.close unless io.closed? }
            @request_pipes.delete(request.id)
            @queued_bytes -= request.wire.bytesize
            @retained_reply_bytes -= request.bytes
            @exchanges.delete(request.id)
            @exchange_changed.signal
          end
          failure ||= request.error
          self.class.__send__(:attach_cleanup_details, failure, errors) if failure && !errors.empty?
        end
        return request.result if request.result
        raise failure if failure
      end
      private :exchange_request

      def close(timeout: 0.5)
        ensure_owner
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0 && timeout <= 0.5
          raise ArgumentError, "control close timeout must be between zero and 0.5 seconds"
        end
        request_close
        errors = []
        deadline = clock + timeout
        @scope.__send__(:join_task, @worker, deadline, errors) if @worker
        until @exchanges.empty?
          remaining = deadline - clock
          unless remaining.positive?
            errors << "control exchange cleanup remains pending"
            break
          end
          begin
            ::Async::Task.current.with_timeout(remaining) { @exchange_changed.wait }
          rescue ::Async::Cancel
            next
          rescue ::Async::TimeoutError
            errors << "control exchange cleanup remains pending"
            break
          end
        end
        errors.concat(@cleanup_errors)
        unless errors.empty?
          raise TransportError.new("Async control cleanup failed", phase: :retire, pid: @pid, cleanup_errors: errors)
        end
        nil
      end

      def closed?
        super && @exchanges.empty? && @driver.retired?
      end

      private

      def start
        @worker.run
        ::Async::Task.current.with_timeout(0.4) do
          @startup_changed.wait until @pid || @transport_failure || @worker.finished?
        end
        if !@pid && @transport_failure
          errors = []
          @scope.__send__(:join_task, @worker, clock + 0.4, errors)
          errors.concat(@cleanup_errors)
          self.class.__send__(:attach_cleanup_details, @transport_failure, errors) unless errors.empty?
          raise @transport_failure
        end

        self
      end

      def retired?
        (!@worker || @worker.finished?) && (!@driver || @driver.retired?) && (!@exchanges || @exchanges.empty?)
      end

      def ensure_owner
        @scope.__send__(:ensure_owner)
      end

      def build_subscription(**options)
        ControlSubscription.new(scope: @scope, **options)
      end

      def wake(writer)
        super if writer
        @writer_changed.signal
        @driver&.__send__(:notify_state)
      end

      def receive_bytes(bytes)
        @parser.feed(bytes) { |record| receive(record) }
        @writer_changed.signal
      end

      def transport_stopping?
        @stopping
      end

      def finish_transport(failure, errors = nil)
        @transport_failure ||= failure
        @startup_changed.signal
        if errors
          @cleanup_errors = errors.freeze
          @finished = true
          return
        end
        @stopping = true
        @requests.values.each do |request|
          type = failure ? failure.class : ClosedError
          complete(request, error: type.new(failure ? failure.message : "control connection closed",
            delivery: request.offset.zero? ? :not_sent : :possibly_sent, phase: :control, pid: @pid))
        end
        @queue.clear
        @replies.clear
        @writing = nil
        @subscriptions.each { |subscription| subscription.__send__(:finish, failure) }
        @writer_changed.signal
      end

      class ControlDriver < ProcessDriver
        def initialize(connection, scope, argv)
          super(scope, nil, argv.freeze, "".b, Float::INFINITY, nil,
            {cleanup_timeout: 0.4, drain_timeout: 0.1})
          @connection = connection
        end

        def call
          failure = nil
          begin
            spawn
            @connection.instance_variable_set(:@pid, @pid)
            @connection.instance_variable_get(:@startup_changed).signal
            start_task { read_control }
            start_task { read_errors }
            start_task { write_control }
            start_task do
              until @child.observed? || @child.observation_error
                @child.reader.read_nonblock(16_384, exception: false)
                Fiber.scheduler.io_wait(@child.reader, IO::READABLE) unless @child.observed? || @child.observation_error
              end
              raise TransportError.new("control exit observation failed", phase: :wait, pid: @pid) if @child.observation_error

              @exit_deadline = clock + 0.1
            end
            until @connection.__send__(:transport_stopping?)
              raise @failure if @failure

              if @exit_deadline
                remaining = @exit_deadline - clock
                raise TransportError.new("control client exited while a pipe remained open", phase: :read) unless remaining.positive?

                ::Async::Task.current.with_timeout(remaining) { @changed.wait }
              else
                @changed.wait
              end
            end
          rescue Exception => error
            failure = error.is_a?(Error) ? error : TransportError.new("Async control transport failed (#{error.class})", phase: :read, pid: @pid)
          ensure
            @connection.__send__(:finish_transport, failure)
            errors = cleanup
            @connection.__send__(:finish_transport, failure, errors)
          end
        end

        private

        def notify_state
          @changed.signal
        end

        def read_control
          loop do
            data = @stdout.read_nonblock(16_384, exception: false)
            case data
            when :wait_readable then Fiber.scheduler.io_wait(@stdout, IO::READABLE)
            when nil
              @connection.instance_variable_get(:@parser).finish
              raise TransportError.new("control client output closed", phase: :read, pid: @pid)
            when String
              @connection.__send__(:receive_bytes, data)
              @changed.signal
            end
          end
        end

        def read_errors
          loop do
            data = @stderr.read_nonblock(16_384, exception: false)
            case data
            when :wait_readable then Fiber.scheduler.io_wait(@stderr, IO::READABLE)
            when nil then return
            when String
              @connection.__send__(:receive_stderr, data.bytesize)
            end
          end
        end

        def write_control
          until @connection.__send__(:transport_stopping?)
            request = @connection.__send__(:pending_write)
            unless request
              @connection.instance_variable_get(:@writer_changed).wait
              next
            end
            written = @writer.write_nonblock(request.wire.byteslice(request.offset, 16_384), exception: false)
            if written == :wait_writable
              Fiber.scheduler.io_wait(@writer, IO::WRITABLE)
            else
              request.offset += written
            end
          end
        end
      end
      private_constant :ControlDriver
    end
  end
end
