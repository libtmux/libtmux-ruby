# frozen_string_literal: true

require "libtmux/endpoint"
require "libtmux/child"

module LibTmux
  class GuardedBlock
    attr_reader :guard, :body, :terminator, :bytesize

    def initialize(guard:, body:, terminator:, bytesize:, opening:, closing:)
      @guard, @body, @terminator, @bytesize = guard.freeze, body.b.freeze, terminator, bytesize
      @opening, @closing = opening.b.freeze, closing.b.freeze
      freeze
    end

    def raw
      (@opening + body + @closing).freeze
    end

    def guard_success?
      terminator == :end
    end

    def inspect
      "#<#{self.class} guard=#{guard.inspect} terminator=#{terminator} bytes=#{bytesize}>"
    end
  end

  # Blocks observed between private boundaries may include hooks. They do not
  # establish command ownership, final status, or completion of delayed effects.
  class GuardedReply
    attr_reader :request_id, :blocks, :generation

    def initialize(request_id:, blocks:, generation:)
      @request_id, @blocks, @generation = request_id, blocks.freeze, generation
      freeze
    end

    def delivery
      :observed
    end

    def attribution
      :boundary_window
    end

    def inspect
      "#<#{self.class} request_id=#{request_id} blocks=#{blocks.length} attribution=#{attribution}>"
    end
  end

  class ControlEvent
    attr_reader :kind, :raw, :data, :pane_id, :sequence, :generation,
      :lost_sequences, :dropped_bytes, :reason, :previous_generation

    def initialize(kind:, raw:, data: nil, pane_id: nil, sequence: nil, generation: nil,
      lost_sequences: nil, dropped_bytes: 0, reason: nil, previous_generation: nil)
      @kind, @raw, @data = kind, raw.b.freeze, data&.b&.freeze
      @pane_id, @sequence, @generation = pane_id&.dup&.freeze, sequence, generation&.dup&.freeze
      @lost_sequences, @dropped_bytes = lost_sequences&.dup&.freeze, dropped_bytes
      @reason, @previous_generation = reason, previous_generation&.dup&.freeze
      freeze
    end

    def bytesize
      raw.bytesize + (data&.bytesize || 0)
    end

    def inspect
      "#<#{self.class} kind=#{kind} sequence=#{sequence} bytes=#{bytesize}>"
    end
  end

  class SubscriptionOverflow < CapacityError
    attr_reader :sequence

    def initialize(sequence:)
      @sequence = sequence
      super("control subscription exceeded its buffer limit", delivery: :observed, phase: :subscription)
    end
  end

  class ControlSubscription
    include Enumerable
    attr_reader :generation

    def initialize(max_bytes: 1 << 20, max_events: 1024, mode: :reliable, pane_id: nil, generation: nil)
      unless [max_bytes, max_events].all? { |limit| limit.is_a?(Integer) && limit.positive? }
        raise ArgumentError, "subscription limits must be positive integers"
      end
      raise ArgumentError, "subscription mode must be reliable or tail" unless [:reliable, :tail].include?(mode)

      @max_bytes, @max_events, @mode, @pane_id = max_bytes, max_events, mode, pane_id
      @owner_pid = Process.pid
      @generation = generation&.dup&.freeze
      @mutex, @changed = Mutex.new, ConditionVariable.new
      @queue, @bytes, @closed = [], 0, false
    end

    def next(timeout: nil)
      ensure_owner
      unless timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0)
        raise ArgumentError, "timeout must be finite and nonnegative"
      end
      deadline = timeout && clock + timeout
      @mutex.synchronize do
        while true
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

          remaining = deadline && deadline - clock
          raise DeadlineExceeded.new("control event deadline elapsed", phase: :subscription) if remaining && remaining <= 0

          @changed.wait(@mutex, remaining)
        end
      end
    end

    def each
      return enum_for(__method__) unless block_given?

      while true
        event = begin
          self.next
        rescue StopIteration
          break
        end
        yield event
      end
      self
    end

    def close
      ensure_owner
      @mutex.synchronize do
        @closed = true
        @queue.clear
        @bytes, @gap, @failure = 0, nil, nil
        @changed.broadcast
      end
      nil
    end

    def closed?
      ensure_owner
      @mutex.synchronize { @closed }
    end

    def inspect
      "#<#{self.class} mode=#{@mode} #{@closed ? 'closed' : 'open'}>"
    end

    private

    def ensure_owner
      raise ClosedError.new("control subscription belongs to another process", phase: :subscription) unless Process.pid == @owner_pid
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def publish(event)
      if @pane_id
        return if event.pane_id ? event.pane_id != @pane_id : event.kind != :gap
      end

      @mutex.synchronize do
        return if @closed

        if @mode == :reliable && (@bytes + event.bytesize > @max_bytes || @queue.length >= @max_events)
          @failure = SubscriptionOverflow.new(sequence: event.sequence)
          @closed = true
        else
          while !@queue.empty? && (@bytes + event.bytesize > @max_bytes || @queue.length >= @max_events)
            dropped = @queue.shift
            @bytes -= dropped.bytesize
            record_gap(dropped)
          end
          if event.bytesize > @max_bytes
            record_gap(event)
          else
            @queue << event
            @bytes += event.bytesize
          end
        end
        @changed.broadcast
      end
    end

    def finish(failure = nil)
      @mutex.synchronize do
        @failure ||= failure
        @closed = true
        @changed.broadcast
      end
    end

    def record_gap(event)
      first = @gap ? @gap.lost_sequences.first : event.sequence
      unknown_loss = (@gap && @gap.dropped_bytes.nil?) || (event.kind == :gap && event.dropped_bytes.nil?)
      bytes = unknown_loss ? nil : (@gap&.dropped_bytes || 0) + event.bytesize
      @gap = ControlEvent.new(kind: :gap, raw: "".b, sequence: event.sequence,
        generation: event.generation, lost_sequences: [first, event.sequence], dropped_bytes: bytes,
        reason: :overflow, previous_generation: @gap&.previous_generation || event.previous_generation)
    end
  end

  module Internal
    class ControlParser
      GUARD = /\A%(begin|end|error) ([0-9]{1,20}) ([0-9]{1,10}) ([0-9]{1,10})\n\z/n
      private_constant :GUARD

      def initialize(max_line_bytes: 1 << 18, max_frame_bytes: 1 << 20)
        unless [max_line_bytes, max_frame_bytes].all? { |n| n.is_a?(Integer) && n.positive? }
          raise ArgumentError, "control parser limits must be positive integers"
        end
        @max_line, @max_frame = max_line_bytes, max_frame_bytes
        @pending = +"".b
      end

      def feed(bytes)
        # Callers feed bounded read chunks; retained data is checked per line.
        bytes.b.each_line("\n") do |part|
          @pending << part
          raise CapacityError.new("control line exceeds its byte limit", phase: :read) if @pending.bytesize > @max_line
          next unless @pending.end_with?("\n")

          line, @pending = @pending, +"".b
          match = GUARD.match(line)
          tuple = match && match.captures.drop(1).map(&:to_i)
          if @guard
            @frame_bytes += line.bytesize
            raise CapacityError.new("control frame exceeds its byte limit", phase: :read) if @frame_bytes > @max_frame

            if match && match[1] != "begin" && tuple == @guard
              yield GuardedBlock.new(guard: @guard, body: @body,
                terminator: match[1].to_sym, bytesize: @frame_bytes, opening: @opening, closing: line)
              @guard = @body = nil
            else
              @body << line
            end
          elsif match
            raise ProtocolError.new("control closing guard has no opening guard", phase: :read) unless match[1] == "begin"

            @guard, @body, @frame_bytes = tuple, +"".b, line.bytesize
            @opening = line
            raise CapacityError.new("control frame exceeds its byte limit", phase: :read) if @frame_bytes > @max_frame
          else
            yield event(line)
          end
        end
      end

      def finish
        return if @pending.empty? && !@guard

        raise ProtocolError.new("control stream ended inside a line or guarded block", phase: :read)
      end

      private

      def event(line)
        if (match = /\A%output (%[0-9]+) (.*)\n\z/n.match(line))
          ControlEvent.new(kind: :output, raw: line, pane_id: match[1], data: decode(match[2]))
        elsif (match = /\A%extended-output (%[0-9]+) [0-9]+(?: [^\n]*?)? : (.*)\n\z/n.match(line))
          ControlEvent.new(kind: :output, raw: line, pane_id: match[1], data: decode(match[2]))
        elsif line.start_with?("%output ", "%extended-output ")
          raise ProtocolError.new("malformed control output event", phase: :read)
        elsif (match = /\A%(pause|continue) (%[0-9]+)\n\z/n.match(line))
          ControlEvent.new(kind: :gap, raw: line, pane_id: match[2],
            reason: match[1] == "pause" ? :pause : :resume, dropped_bytes: nil)
        elsif line.start_with?("%pause ", "%continue ")
          raise ProtocolError.new("malformed control flow event", phase: :read)
        else
          ControlEvent.new(kind: :notice, raw: line)
        end
      end

      def decode(bytes)
        decoded = +"".b
        index = 0
        while index < bytes.bytesize
          if bytes.getbyte(index) == 92
            digits = bytes.byteslice(index + 1, 3)
            unless digits && /\A[0-3][0-7]{2}\z/n.match?(digits)
              raise ProtocolError.new("malformed control output escape", phase: :read)
            end
            decoded << digits.to_i(8)
            index += 4
          else
            decoded << bytes.getbyte(index)
            index += 1
          end
        end
        decoded
      end
    end
  end
end

module LibTmux
  class ControlConnection
    module CleanupDetails
      attr_reader :control_cleanup_errors
    end

    Request = Struct.new(:id, :wire, :offset, :start_marker, :end_marker, :started,
      :blocks, :bytes, :reader, :writer, :result, :error, :flow, :flow_reported, keyword_init: true)
    private_constant :Request, :CleanupDetails

    attr_reader :pid, :generation, :previous_generation, :events, :cleanup_errors

    def self.open(**options)
      return new(**options) unless block_given?

      connection = result = error = nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          begin
            connection = new(**options)
            Thread.handle_interrupt(Exception => :immediate) { result = yield connection }
          rescue Exception => failure
            error = failure
          ensure
            begin
              connection&.close
            rescue Exception => cleanup
              attach_cleanup_details(error, ["control cleanup failed (#{cleanup.class})"]) if error
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

    def self.attach_cleanup_details(error, details)
      if error.is_a?(Error)
        error.send(:attach_cleanup_errors, details)
      else
        error.extend(CleanupDetails)
        previous = error.control_cleanup_errors || []
        error.instance_variable_set(:@control_cleanup_errors, (previous + details).freeze)
      end
    rescue FrozenError, TypeError
      nil
    end
    private_class_method :attach_cleanup_details

    def initialize(binding:, session_id:, reconnect: nil, max_requests: 32, max_command_bytes: 1 << 18,
      max_queue_bytes: 1 << 20, max_line_bytes: 1 << 18, max_reply_bytes: 1 << 20,
      max_stderr_bytes: 1 << 18, max_subscriptions: 32)
      initialize_state(binding_key: binding.key, session_id: session_id, reconnect: reconnect,
        max_requests: max_requests, max_command_bytes: max_command_bytes,
        max_queue_bytes: max_queue_bytes, max_line_bytes: max_line_bytes, max_reply_bytes: max_reply_bytes,
        max_stderr_bytes: max_stderr_bytes, max_subscriptions: max_subscriptions)
      error = nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          begin
            process_wait = Internal::ProcessWait.new
            prefix = binding.command_prefix
            @pin = Internal::SocketIdentity.new(Endpoint.new(socket_path: prefix.last, executable: prefix.first))
            @wake_reader, @wake_writer = pipe
            input_reader, @input = pipe
            @output, output_writer = pipe
            @error_output, error_writer = pipe
            @child = Internal::OwnedChild.new(process_wait)
            @exit_reader = @child.reader
            @resources << @exit_reader
            begin
              @pid = Process.spawn({"TMUX" => nil, "TMUX_PANE" => nil},
                *@pin.command_prefix, "-C", "attach-session", "-t", session_id,
                in: input_reader, out: output_writer, err: error_writer, close_others: true)
            ensure
              @child.spawned(@pid)
            end
            [input_reader, output_writer, error_writer].each(&:close)
            @worker = Thread.new { run }
            Thread.handle_interrupt(Exception => :immediate) { nil }
          rescue Exception => failure
            error = failure
            if @worker
              @mutex.synchronize { @stopping = true; wake(@wake_writer) }
              @worker.join(0.5)
            else
              cleanup
            end
          end
        end
      rescue Exception => deferred
        error ||= deferred
      end
      self.class.send(:attach_cleanup_details, error, @cleanup_errors) if error && !@cleanup_errors.empty?
      raise error if error
    end

    def exchange(line, timeout: 5, cancel: nil)
      exchange_request(line, timeout: timeout, cancel: cancel)
    end

    def exchange_request(line, timeout:, cancel:, flow: nil)
      ensure_owner
      unless line.is_a?(String) && !line.empty? && !line.b.match?(/[\x00\r\n]/n)
        raise ArgumentError, "control input must be one nonempty raw command line without NUL or line endings"
      end
      unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
        raise ArgumentError, "control timeout must be positive and finite"
      end
      raise CapacityError.new("control command exceeds its byte limit", phase: :admission) if line.bytesize > @max_command

      deadline, request, result, error = clock + timeout, nil, nil, nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          begin
            request = admit(line, cancel, flow: flow)
            Thread.handle_interrupt(Exception => :immediate) do
              loop do
                result, error = @mutex.synchronize { [request.result, request.error] }
                break if result || error

                if cancel&.cancelled?
                  abort_request(request, Cancelled, "control request cancelled")
                  next
                end
                remaining = deadline - clock
                if remaining <= 0
                  abort_request(request, DeadlineExceeded, "control request deadline elapsed")
                  next
                end
                IO.select([request.reader, cancel&.reader].compact, nil, nil, remaining)
              end
            end
          rescue Exception => failure
            error ||= failure
          ensure
            if request
              begin
                abort_request(request, Cancelled, "control request interrupted")
              rescue Exception => cleanup
                self.class.send(:attach_cleanup_details, error, ["control request cleanup failed (#{cleanup.class})"]) if error
                error ||= cleanup
              ensure
                @mutex.synchronize do
                  [request.reader, request.writer].each { |io| io.close unless io.closed? }
                  @request_pipes.delete(request.id)
                  @queued_bytes -= request.wire.bytesize
                end
              end
            end
          end
        end
      rescue Exception => deferred
        error ||= deferred
      end
      return result if result
      raise error if error
    end
    private :exchange_request

    def pause_output(pane_id:, timeout: 5, cancel: nil)
      change_output(pane_id, "pause", timeout, cancel)
    end

    def resume_output(pane_id:, timeout: 5, cancel: nil)
      change_output(pane_id, "continue", timeout, cancel)
    end

    def subscribe(pane_id: nil, mode: :reliable, max_bytes: 1 << 20, max_events: 1024)
      ensure_owner
      unless pane_id.nil? || (pane_id.is_a?(String) && /\A%[0-9]+\z/.match?(pane_id))
        raise ArgumentError, "pane subscription must use an exact pane ID"
      end
      @mutex.synchronize do
        raise ClosedError.new("control connection is closed", phase: :admission) if @stopping || @finished

        @subscriptions.reject!(&:closed?)
        raise CapacityError.new("control subscription limit reached", phase: :admission) if @subscriptions.length >= @max_subscriptions

        subscription = build_subscription(pane_id: pane_id, mode: mode, max_bytes: max_bytes, max_events: max_events,
          generation: @generation)
        subscription.send(:publish, @reconnect_gap) if @reconnect_gap
        @subscriptions << subscription
        subscription
      end
    end

    def close(timeout: 0.5)
      unless timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0 && timeout <= 0.5
        raise ArgumentError, "control close timeout must be between zero and 0.5 seconds"
      end
      unless Process.pid == @owner_pid
        @child&.detach
        (@resources + @request_pipes.values.flatten).each { |io| io.close unless io.closed? }
        @pin&.close
        return nil
      end
      failure = nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          request_close
          unless !@worker || @worker.join(timeout)
            failure = TransportError.new("control reader did not retire within its cleanup deadline", phase: :cleanup, pid: @pid)
          end
          unless @cleanup_errors.empty?
            failure ||= TransportError.new("control cleanup failed", phase: :cleanup, pid: @pid, cleanup_errors: @cleanup_errors)
          end
        end
      rescue Exception => deferred
        failure ||= deferred
      end
      raise failure if failure

      nil
    end

    def closed?
      ensure_owner
      @mutex.synchronize { !!(@finished && @cleanup_errors.empty?) }
    end

    def inspect
      "#<#{self.class} pid=#{@pid} generation=#{@generation} #{@stopping || @finished ? 'closed' : 'open'}>"
    end

    private

    def initialize_state(binding_key:, session_id:, reconnect: nil, max_requests: 32, max_command_bytes: 1 << 18,
      max_queue_bytes: 1 << 20, max_line_bytes: 1 << 18, max_reply_bytes: 1 << 20,
      max_stderr_bytes: 1 << 18, max_subscriptions: 32)
      unless session_id.is_a?(String) && /\A\$[0-9]+\z/.match?(session_id)
        raise ArgumentError, "control session must be an exact session ID"
      end
      limits = [max_requests, max_command_bytes, max_queue_bytes, max_line_bytes,
        max_reply_bytes, max_stderr_bytes, max_subscriptions]
      raise ArgumentError, "control limits must be positive integers" unless limits.all? { |n| n.is_a?(Integer) && n.positive? }
      if reconnect
        unless reconnect.is_a?(ControlConnection) && reconnect.closed? &&
            reconnect.instance_variable_get(:@binding_key) == binding_key &&
            reconnect.instance_variable_get(:@session_id) == session_id
          raise ArgumentError, "reconnect requires a retired control connection for the same binding and session"
        end
        @previous_generation = reconnect.generation
      end

      @owner_pid, @generation = Process.pid, SecureRandom.hex(16).freeze
      @binding_key, @session_id = binding_key, session_id.dup.freeze
      @mutex = Mutex.new
      @queue, @requests, @request_pipes, @subscriptions, @resources = [], {}, {}, [], []
      @replies = []
      @next_id, @queued_bytes, @sequence = 0, 0, 0
      if @previous_generation
        @sequence += 1
        @reconnect_gap = ControlEvent.new(kind: :gap, raw: "".b, sequence: @sequence,
          generation: @generation, previous_generation: @previous_generation, reason: :reconnect, dropped_bytes: nil)
      end
      @max_requests, @max_command, @max_queue = max_requests, max_command_bytes, max_queue_bytes
      @max_reply, @max_stderr, @max_subscriptions = max_reply_bytes, max_stderr_bytes, max_subscriptions
      @parser = Internal::ControlParser.new(max_line_bytes: max_line_bytes, max_frame_bytes: max_reply_bytes)
      @stderr_bytes, @cleanup_errors = 0, [].freeze
      @events = subscribe
    end

    def build_subscription(**options)
      ControlSubscription.new(**options)
    end

    def change_output(pane_id, state, timeout, cancel)
      unless pane_id.is_a?(String) && /\A%[0-9]+\z/.match?(pane_id)
        raise ArgumentError, "control output target must be an exact pane ID"
      end
      flow = [pane_id.dup.freeze, state == "pause" ? :pause : :resume].freeze
      exchange_request("refresh-client -A '#{pane_id}:#{state}'", timeout: timeout, cancel: cancel, flow: flow)
    end

    def ensure_owner
      raise ClosedError.new("control connection belongs to another process", phase: :admission) unless Process.pid == @owner_pid
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def pipe
      IO.pipe.tap { |pair| @resources.concat(pair); pair.each(&:binmode) }
    end

    def request_close
      ensure_owner
      @mutex.synchronize { @stopping = true; wake(@wake_writer) }
      nil
    end

    def wake(writer)
      writer&.write_nonblock("x", exception: false) unless writer&.closed?
    rescue IOError, Errno::EPIPE
      nil
    end

    def abort_request(request, type, message)
      @mutex.synchronize do
        return if request.result || request.error

        delivery = request.offset.zero? ? :not_sent : :possibly_sent
        if request.offset.zero?
          @queue.delete(request)
          @replies.delete(request)
          @writing = nil if @writing.equal?(request)
        else
          # Do not reuse an undrained boundary after cancellation.
          @stopping = true
        end
        complete(request, error: type.new(message, delivery: delivery, phase: :control, pid: @pid))
        wake(@wake_writer)
      end
    end

    def admit(line, cancel, flow: nil)
      @mutex.synchronize do
        raise ClosedError.new("control connection is closed", phase: :admission) if @stopping || @finished
        raise Cancelled.new("control request cancelled before admission", phase: :admission) if cancel&.cancelled?

        start_marker = "libtmux_boundary_#{SecureRandom.hex(24)}"
        end_marker = "libtmux_boundary_#{SecureRandom.hex(24)}"
        wire = "#{start_marker}\n".b + line.b + "\n#{end_marker}\n".b
        if @request_pipes.length >= @max_requests || @queued_bytes + wire.bytesize > @max_queue
          raise CapacityError.new("control admission limit reached", phase: :admission)
        end
        reader, writer = IO.pipe
        begin
          request = Request.new(id: (@next_id += 1), wire: wire, offset: 0,
            start_marker: start_marker, end_marker: end_marker, started: false,
            blocks: [], bytes: 0, reader: reader, writer: writer, flow: flow)
        rescue Exception
          [reader, writer].each { |io| io.close unless io.closed? }
          raise
        end
        @request_pipes[request.id] = [reader, writer]
        @requests[request.id] = request
        @queue << request
        @queued_bytes += wire.bytesize
        wake(@wake_writer)
        request
      end
    end

    def complete(request, result: nil, error: nil)
      return if request.result || request.error

      if request.flow && !request.flow_reported && request.offset.positive?
        publish_event(ControlEvent.new(kind: :gap, raw: "".b, pane_id: request.flow.first,
          reason: request.flow.last == :pause ? :pause_requested : :resume_requested, dropped_bytes: nil))
        request.flow_reported = true
      end

      request.result, request.error = result, error
      @requests.delete(request.id)
      wake(request.writer)
    end

    def run
      Thread.current.report_on_exception = false
      failure, exit_deadline = nil, nil
      streams = [@output, @error_output]
      loop do
        writing = pending_write
        break if @mutex.synchronize { @stopping }
        raise TransportError.new("control client exited while a pipe remained open", phase: :read) if exit_deadline && clock >= exit_deadline

        ready = IO.select(streams + [@wake_reader, @exit_reader], writing ? [@input] : nil,
          nil, exit_deadline && [exit_deadline - clock, 0].max)
        next unless ready

        ready[0].each do |io|
          data = io.read_nonblock(16_384, exception: false)
          if io == @wake_reader
            next
          elsif io == @exit_reader
            if @child.observation_error
              raise TransportError.new("control exit observation failed (#{@child.observation_error.class})", phase: :wait)
            end
            exit_deadline ||= clock + 0.1
            next
          elsif data.nil?
            streams.delete(io)
            if io == @output
              @parser.finish
              raise TransportError.new("control client output closed", phase: :read)
            end
          elsif data.is_a?(String)
            if io == @output
              @parser.feed(data) { |record| receive(record) }
            else
              @stderr_bytes += data.bytesize
              raise CapacityError.new("control stderr exceeds its byte limit", phase: :read) if @stderr_bytes > @max_stderr
            end
          end
        end
        unless ready[1].empty?
          @mutex.synchronize do
            request = @writing
            if request && !@stopping
              sent = @input.write_nonblock(request.wire.byteslice(request.offset, 16_384), exception: false)
              request.offset += sent if sent.is_a?(Integer)
            end
          end
        end
      end
    rescue Exception => error
      failure = error.is_a?(Error) ? error : TransportError.new("control transport failed (#{error.class})", phase: :read)
    ensure
      Thread.handle_interrupt(Exception => :never) do
        @mutex.synchronize do
          @stopping = true
          @requests.values.each do |request|
            type = failure ? failure.class : ClosedError
            error = type.new(failure ? failure.message : "control connection closed",
              delivery: request.offset.zero? ? :not_sent : :possibly_sent, phase: :control, pid: @pid)
            complete(request, error: error)
          end
          @queue.clear
          @replies.clear
          @writing = nil
          @subscriptions.each { |subscription| subscription.send(:finish, failure) }
        end
        cleanup
        @mutex.synchronize { @finished = true }
      end
    end

    def pending_write
      @mutex.synchronize do
        return nil if @stopping

        @writing = nil if @writing && @writing.offset == @writing.wire.bytesize
        unless @writing
          @writing = @queue.shift
          @replies << @writing if @writing
        end
        @writing
      end
    end

    def receive(record)
      @mutex.synchronize do
        request = @replies.first
        if record.is_a?(GuardedBlock) && request
          if marker?(record, request.start_marker)
            raise ProtocolError.new("duplicate control start boundary", phase: :read) if request.started

            request.started = true
            return
          elsif marker?(record, request.end_marker)
            raise ProtocolError.new("control end boundary preceded its start", phase: :read) unless request.started

            reply = GuardedReply.new(request_id: request.id, blocks: request.blocks, generation: @generation)
            complete(request, result: reply)
            @replies.shift
            return
          elsif request.started
            request.bytes += record.bytesize
            raise CapacityError.new("control reply exceeds its byte limit", phase: :read) if request.bytes > @max_reply

            request.blocks << record
            return
          end
        end
        if request&.flow && record.is_a?(ControlEvent) && record.kind == :gap &&
            record.pane_id == request.flow.first && record.reason == request.flow.last
          request.flow_reported = true
        end
        publish_event(record)
        @stopping = true if record.is_a?(ControlEvent) && (record.raw == "%exit\n".b || record.raw.start_with?("%exit "))
      end
    end

    def publish_event(record)
      @sequence += 1
      event = if record.is_a?(GuardedBlock)
        ControlEvent.new(kind: :unattributed_block, raw: record.raw,
          sequence: @sequence, generation: @generation)
      else
        ControlEvent.new(kind: record.kind, raw: record.raw, data: record.data, pane_id: record.pane_id,
          sequence: @sequence, generation: @generation, reason: record.reason,
          previous_generation: record.previous_generation, lost_sequences: record.lost_sequences,
          dropped_bytes: record.dropped_bytes)
      end
      @subscriptions.each { |subscription| subscription.send(:publish, event) }
    end

    def marker?(block, marker)
      block.terminator == :error && block.guard.last == 1 &&
        block.body == "parse error: unknown command: #{marker}\n".b
    end

    def cleanup
      errors = []
      deadline = clock + 0.4
      attempt = lambda do |label, &operation|
        operation.call
      rescue Exception => error
        errors << "#{label} failed (#{error.class})"
      end
      attempt.call("control input close") { @input.close if @input && !@input.closed? }
      if @pid
        attempt.call("control client termination") { signal("TERM") }
        attempt.call("control exit observer join") do
          @child.wait_observed([deadline - clock, 0.05].min.clamp(0, 0.05))
        end
        attempt.call("control client forced termination") { signal("KILL") } unless @child.observed?
        @child.finish_signalling
        attempt.call("control exit observer join") do
          errors << "control client reap deferred after cleanup deadline" unless @child.join([deadline - clock, 0].max)
        end
      else
        attempt.call("control exit observer join") { @child&.join([deadline - clock, 0].max) }
      end
      @resources.each { |io| attempt.call("control pipe close") { io.close unless io.closed? } }
      attempt.call("control route close") { @pin&.close }
      errors << "control exit observation failed (#{@child.observation_error.class})" if @child&.observation_error
      errors << "control fallback reap failed (#{@child.retirement_error.class})" if @child&.retirement_error
      @cleanup_errors = errors.freeze
    end

    def signal(name)
      @child&.signal(name)
    end
  end
end
