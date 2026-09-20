# frozen_string_literal: true

require "libtmux/async/process"

module LibTmux
  module Async
    class Scope
      Request = Struct.new(:bytes, :task, :execution, :result, :error, :active, :output_bytes, keyword_init: true)
      private_constant :Request

      attr_reader :server

      def initialize(parent:, server:, concurrency: 4, max_requests: 32, max_controls: 4, max_queue_bytes: 1 << 22,
        max_output_bytes: 1 << 23, stdout_limit: 1 << 20, stderr_limit: 1 << 18,
        input_limit: 1 << 20, argv_limit: 1 << 18, cleanup_timeout: 0.5, drain_timeout: 0.5)
        unless ::Async::Task.current? && parent.is_a?(::Async::Task) && !parent.finished? && parent.root.equal?(Fiber.scheduler)
          raise ArgumentError, "parent must be a live task on the current Async scheduler"
        end
        [concurrency, max_requests, max_controls, max_queue_bytes, max_output_bytes, stdout_limit, stderr_limit, input_limit, argv_limit].each do |value|
          raise ArgumentError, "scope limits must be positive Integers" unless value.is_a?(Integer) && value.positive?
        end
        [cleanup_timeout, drain_timeout].each do |value|
          raise ArgumentError, "cleanup deadlines must be positive and finite" unless value.is_a?(Numeric) && value.finite? && value.positive?
        end
        @parent, @thread, @pid, @scheduler = parent, Thread.current, Process.pid, Fiber.scheduler
        @concurrency, @max_requests, @max_queue, @max_output = concurrency, max_requests, max_queue_bytes, max_output_bytes
        @controls, @max_controls = [], max_controls
        @limits = {stdout: stdout_limit, stderr: stderr_limit, input: input_limit, argv: argv_limit,
          cleanup_timeout: cleanup_timeout, drain_timeout: drain_timeout}.freeze
        @requests, @waiting, @maps = [], [], []
        @active = @queued_bytes = @output_bytes = 0
        @changed = ::Async::Notification.new
        @server = Server.new(self, server)
      end

      def close
        ensure_owner
        if @maps.flatten.include?(::Async::Task.current?)
          raise ClosedError.new("cannot close an Async scope from its active map worker", phase: :retire)
        end
        @closed = true
        deadline = clock + @limits.fetch(:cleanup_timeout) * 2
        errors = []
        @controls.each { |control| control.__send__(:request_close) }
        @maps.flatten.each { |task| cancel_task(task, deadline, errors) }
        @requests.dup.each { |request| cancel_task(request.task, deadline, errors) }
        @maps.flatten.each { |task| join_task(task, deadline, errors) }
        @controls.dup.each do |control|
          begin
            control.close(timeout: (deadline - clock).clamp(0, 0.5))
            @controls.delete(control)
          rescue Exception => error
            errors << "control close failed (#{error.class})"
            errors.concat(error.cleanup_errors) if error.is_a?(Error)
          end
        end
        @requests.dup.each do |request|
          begin
            request.task.wait(timeout: [deadline - clock, 0].max) unless request.task.finished?
          rescue ::Async::Cancel
            retry if clock < deadline
          rescue Exception => error
            errors << "request join failed (#{error.class})"
          end
          if request.execution && !request.execution.retired?
            errors.concat(request.execution.cleanup)
            release_active(request) if request.execution.retired?
          end
          errors.concat(request.error.cleanup_errors) if request.error.is_a?(Error)
          if !request.execution || request.execution.retired?
            release(request)
          else
            errors << "request ownership remains pending"
          end
        end
        raise TransportError.new("Async scope cleanup failed", phase: :retire, cleanup_errors: errors) unless errors.empty?

        nil
      end

      def closed?
        ensure_owner
        !!@closed
      end

      # Frozen counters and limits from this scope, without I/O or payloads.
      # Process slots remain occupied until retirement; they are not a live PID count.
      # Valid after close on the owning thread, process and scheduler.
      def diagnostics
        ensure_owner
        {transport: :async_process, closed: !!@closed, admitted_requests: @requests.length,
          reserved_process_slots: @requests.length,
          waiting_requests: @waiting.length, active_process_slots: @active,
          reserved_request_bytes: @queued_bytes, retained_output_bytes: @output_bytes,
          control_connections: @controls.count { |control| !control.__send__(:retired?) }, maps: @maps.length,
          limits: {concurrency: @concurrency, max_requests: @max_requests, max_controls: @max_controls,
            max_queue_bytes: @max_queue, max_output_bytes: @max_output,
            stdout_limit: @limits.fetch(:stdout), stderr_limit: @limits.fetch(:stderr),
            input_limit: @limits.fetch(:input), argv_limit: @limits.fetch(:argv),
            cleanup_timeout: @limits.fetch(:cleanup_timeout), drain_timeout: @limits.fetch(:drain_timeout),
            close_timeout: @limits.fetch(:cleanup_timeout) * 2}.freeze}.freeze
      end

      def map(values, concurrency: @concurrency, max_items: 1024, max_bytes: @max_output, result_bytes: nil)
        ensure_open
        unless concurrency.is_a?(Integer) && concurrency.positive? && concurrency <= @max_requests
          raise ArgumentError, "map concurrency must fit scope admission capacity"
        end
        unless [max_items, max_bytes].all? { |value| value.is_a?(Integer) && value.positive? }
          raise ArgumentError, "map limits must be positive Integers"
        end
        raise ArgumentError, "map requires a block" unless block_given?
        raise ArgumentError, "result_bytes must be callable" if result_bytes && !result_bytes.respond_to?(:call)

        source = values.to_enum
        tasks, results = [], []
        @maps << tasks
        next_index = retained = 0
        failure = nil
        begin
          concurrency.times do
            task = ::Async::Task.new(@parent) do
              begin
                loop do
                  break if failure
                  value = begin
                    source.next
                  rescue StopIteration
                    break
                  end
                  index = next_index
                  raise CapacityError.new("ordered map item limit reached", phase: :admission) if index >= max_items

                  next_index += 1
                  result = yield value
                  bytes = result_bytes ? result_bytes.call(result) : retained_bytes(result)
                  unless bytes.is_a?(Integer) && bytes >= 0
                    raise ArgumentError, "result_bytes must return a nonnegative Integer"
                  end
                  if retained + bytes > max_bytes || @output_bytes + bytes > @max_output
                    raise CapacityError.new("ordered map retained output limit reached", phase: :read, delivery: :observed)
                  end
                  retained += bytes
                  @output_bytes += bytes
                  results[index] = result
                end
              rescue Exception => error
                if failure && error.is_a?(Error)
                  Async.__send__(:attach_cleanup, failure, error.cleanup_errors)
                end
                failure ||= error
              ensure
                notify
              end
            end
            tasks << task
            task.run
          end
          until tasks.all?(&:finished?)
            break if failure
            @changed.wait
          end
        rescue Exception => error
          failure ||= error
        ensure
          deadline = clock + @limits.fetch(:cleanup_timeout) * 2
          errors = []
          tasks.each { |task| cancel_task(task, deadline, errors) }
          tasks.each { |task| join_task(task, deadline, errors) }
          @maps.delete(tasks) if tasks.all?(&:finished?)
          @output_bytes -= retained
          if failure
            Async.__send__(:attach_cleanup, failure, errors)
          elsif !failure && !errors.empty?
            failure = TransportError.new("ordered map cleanup failed", phase: :retire, cleanup_errors: errors)
          end
        end
        raise failure if failure

        results.freeze
      end

      private

      attr_reader :parent

      def open_control(binding:, session_id:, **options)
        ensure_open
        @controls.reject!(&:closed?)
        raise CapacityError.new("Async control capacity is exhausted", phase: :admission) if @controls.length >= @max_controls

        control = ControlConnection.allocate
        @controls << control
        begin
          control.__send__(:initialize, scope: self, binding: binding, session_id: session_id, **options)
          control.__send__(:start)
        rescue Exception
          @controls.delete(control) if control.__send__(:retired?)
          raise
        end
        control
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def join_task(task, deadline, errors)
        until task.finished?
          remaining = deadline - clock
          unless remaining.positive?
            errors << "owned task join remains pending"
            break
          end
          begin
            task.wait(timeout: remaining)
          rescue ::Async::Cancel
            next
          rescue Exception => error
            errors << "owned task join failed (#{error.class})"
            break
          end
        end
      end

      def cancel_task(task, deadline, errors)
        task.cancel unless task.finished?
      rescue ::Async::Cancel
        retry if clock < deadline
        errors << "owned task cancellation remains pending"
      rescue Exception => error
        errors << "owned task cancellation failed (#{error.class})"
      end

      def retained_bytes(value)
        nodes = 0
        visiting = {}
        measure = lambda do |item, depth|
          nodes += 1
          if nodes > 2048 || depth > 32
            raise CapacityError.new("ordered map result structure limit reached", phase: :read, delivery: :observed)
          end
          case item
          when nil, true, false, Float then 8
          when Integer then [8, (item.bit_length + 7) / 8].max
          when Symbol then item.to_s.bytesize
          when String then item.bytesize
          when CommandResult then measure.call([item.stdout, item.stderr, item.argv], depth + 1)
          when Array, Hash
            if visiting[item.object_id]
              raise CapacityError.new("ordered map result contains a cycle", phase: :read, delivery: :observed)
            end
            visiting[item.object_id] = true
            begin
              if item.is_a?(Array)
                8 + item.sum { |child| measure.call(child, depth + 1) }
              else
                8 + item.sum { |key, child| measure.call(key, depth + 1) + measure.call(child, depth + 1) }
              end
            ensure
              visiting.delete(item.object_id)
            end
          else
            raise UnsupportedFeatureError.new("ordered map application results require a result_bytes estimator", phase: :read, delivery: :observed)
          end
        end
        measure.call(value, 0)
      end

      def ensure_owner
        unless Process.pid == @pid && Thread.current.equal?(@thread) && Fiber.scheduler.equal?(@scheduler)
          raise ClosedError.new("Async scope belongs to another thread, process or scheduler", phase: :admission)
        end
      end

      def ensure_open
        ensure_owner
        raise ClosedError.new("Async scope is closed", phase: :admission) if @closed || @parent.finished?
      end

      def execute(argv, input: "".b, timeout: 5.0, cancel: nil)
        ensure_open
        deadline = clock + timeout if timeout.is_a?(Numeric) && timeout.finite?
        raise ArgumentError, "timeout must be finite" unless deadline
        unless argv.is_a?(Array) && !argv.empty? && argv.all? { |arg| arg.is_a?(String) && !arg.include?("\0") }
          raise ArgumentError, "argv must be a nonempty Array of Strings without NUL"
        end
        raise ArgumentError, "input must be a String" unless input.is_a?(String)
        if cancel && (!cancel.respond_to?(:reader) || !cancel.respond_to?(:cancelled?))
          raise ArgumentError, "cancel must provide a reader and cancellation state"
        end
        raise Cancelled.new("command cancelled before admission", phase: :admission) if cancel&.cancelled?
        raise DeadlineExceeded.new("command deadline elapsed before admission", phase: :admission) if clock >= deadline

        argv_bytes = argv.sum { |arg| arg.bytesize + 1 }
        bytes = input.bytesize + argv_bytes
        if input.bytesize > @limits.fetch(:input) || argv_bytes > @limits.fetch(:argv) ||
            @requests.length >= @max_requests || @queued_bytes + bytes > @max_queue
          raise CapacityError.new("Async request admission limit reached", phase: :admission)
        end
        ticket = Request.new(bytes: bytes, output_bytes: 0)
        @requests << ticket
        @waiting << ticket
        @queued_bytes += bytes
        ticket.execution = ProcessDriver.new(self, ticket, argv.map { |arg| arg.dup.freeze }.freeze,
          input.b.freeze, deadline, cancel, @limits)
        ticket.task = ::Async::Task.new(@parent) do
          begin
            ticket.result = ticket.execution.call
          rescue Exception => error
            ticket.error = error
          ensure
            notify
          end
        end
        begin
          ticket.task.run
          ticket.task.wait
        rescue Exception => error
          unless ticket.result && error.is_a?(::Async::Cancel)
            errors = []
            failure = error unless error.is_a?(::Async::Cancel)
            deadline = clock + @limits.fetch(:cleanup_timeout) * 2
            cancel_task(ticket.task, deadline, errors)
            join_task(ticket.task, deadline, errors)
            ticket.error = failure || ticket.error || Cancelled.new("command caller was cancelled", **ticket.execution.details(:read))
            Async.__send__(:attach_cleanup, ticket.error, errors)
          end
        end
        raise ticket.error if ticket.error

        ticket.result
      ensure
        if ticket && (!ticket.task || (ticket.task.finished? && ticket.execution.retired?))
          release(ticket)
        end
      end

      def acquire(ticket, deadline, check_cancel)
        loop do
          check_cancel.call(:admission)
          raise ClosedError.new("Async scope is closed", phase: :admission) if @closed
          raise DeadlineExceeded.new("command deadline elapsed in admission", phase: :admission) if clock >= deadline

          if @waiting.first.equal?(ticket) && @active < @concurrency
            @waiting.shift
            @active += 1
            ticket.active = true
            notify
            return
          end
          begin
            ::Async::Task.current.with_timeout(deadline - clock) { @changed.wait }
          rescue ::Async::TimeoutError
            raise DeadlineExceeded.new("command deadline elapsed in admission", phase: :admission)
          end
        end
      end

      def release_active(ticket)
        return unless ticket.active

        ticket.active = false
        @active -= 1
        notify
      end

      def retain_output(ticket, bytes)
        if @output_bytes + bytes > @max_output
          raise CapacityError.new("Async retained output limit reached", **ticket.execution.details(:read))
        end
        @output_bytes += bytes
        ticket.output_bytes += bytes
      end

      def release(ticket)
        return unless @requests.delete(ticket)

        @waiting.delete(ticket)
        @queued_bytes -= ticket.bytes
        @output_bytes -= ticket.output_bytes
        notify
      end

      def notify
        @changed.signal
      end
    end
  end
end
