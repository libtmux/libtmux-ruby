# frozen_string_literal: true

require "mcp"
require "async"
require "async/notification"
require "libtmux/errors"

module LibTmux
  module MCP
    # Owns Async tasks, while the application retains its streams and scheduler.
    class StdioTransport < ::MCP::Transport
      RequestExpired = Class.new(Exception)
      WriteExpired = Class.new(Exception)
      Ticket = Struct.new(:request, :bytes, :deadline, :task, :active, :cancellation, :callback, :state, keyword_init: true)
      Frame = Struct.new(:bytes, :state, keyword_init: true)
      module CleanupDetails
        attr_reader :mcp_cleanup_errors
      end
      private_constant :RequestExpired, :WriteExpired, :Ticket, :Frame, :CleanupDetails

      class Session < ::MCP::ServerSession
        def initialize(adapter:, **options)
          @adapter = adapter
          super(**options)
        end

        def register_in_flight(id)
          super.tap { |token| @adapter.__send__(:bind_cancellation, id, token) if token }
        end
      end

      # Modern envelopes have request-local capabilities and logging state.
      class ModernSession < ::MCP::ServerSession
        def initialize(connection:, **options)
          @connection = connection
          super(**options)
        end

        def register_in_flight(id)
          @connection.register_in_flight(id)
        end

        def unregister_in_flight(id, cancellation: nil)
          @connection.unregister_in_flight(id, cancellation: cancellation)
        end

        def lookup_in_flight(id)
          @connection.lookup_in_flight(id)
        end
      end
      private_constant :Session, :ModernSession

      def initialize(server:, parent:, input:, output:, concurrency: 4, max_requests: 32,
        max_frame_bytes: 1 << 20, max_request_bytes: 1 << 22, max_output_bytes: 1 << 22,
        request_timeout: 30, write_timeout: 0.5, cleanup_timeout: 0.5)
        unless parent.is_a?(::Async::Task) && !parent.finished? && parent.root.equal?(Fiber.scheduler)
          raise ArgumentError, "parent must be a live task on the current Async scheduler"
        end
        raise ArgumentError, "server must be an MCP SDK Server" unless server.is_a?(::MCP::Server)
        unless [input, output].all? { |io| io.is_a?(IO) && !io.closed? }
          raise ArgumentError, "input and output must be open IO streams"
        end
        [concurrency, max_requests, max_frame_bytes, max_request_bytes, max_output_bytes].each do |value|
          raise ArgumentError, "transport limits must be positive Integers" unless value.is_a?(Integer) && value.positive?
        end
        [request_timeout, write_timeout, cleanup_timeout].each do |value|
          raise ArgumentError, "transport deadlines must be positive and finite" unless value.is_a?(Numeric) && value.finite? && value.positive?
        end
        @parent, @input, @output = parent, input, output
        @thread, @pid, @scheduler = Thread.current, Process.pid, Fiber.scheduler
        @concurrency, @max_requests = concurrency, max_requests
        @max_frame, @max_request, @max_output = max_frame_bytes, max_request_bytes, max_output_bytes
        @request_timeout, @write_timeout, @cleanup_timeout = request_timeout, write_timeout, cleanup_timeout
        @tickets, @waiting, @by_id, @by_task, @frames = [], [], {}, {}, []
        @active = @request_bytes = @output_bytes = 0
        @changed, @writable = ::Async::Notification.new, ::Async::Notification.new
        @previous_transport = server.transport
        @session = Session.new(server: server, transport: self, adapter: self)
        super(server)
      end

      def run
        ensure_owner
        raise ClosedError.new("transport cannot be restarted", phase: :admission) if @runner || @closed

        @runner = ::Async::Task.current
        begin
          @writer = child_task { write_loop }
          @writer.run
          @reader = child_task { read_loop }
          @reader.run
          @changed.wait until @input_done || @stopping || @failure
        rescue Exception => error
          @failure ||= error
        ensure
          retire
        end
        raise @failure, cause: nil if @failure

        nil
      end

      def close
        ensure_owner
        return nil if @closed
        if @by_task.key?(::Async::Task.current?)
          raise ClosedError.new("cannot close transport from its own request", phase: :retire)
        end

        @stopping = true
        @changed.signal
        if @runner&.finished?
          retire
          raise @failure, cause: nil unless @closed
        elsif @runner && !@runner.current?
          @runner.wait(timeout: @cleanup_timeout * 2)
        elsif !@runner
          @closed = true
          restore_transport
        end
        nil
      end

      def closed?
        !!@closed
      end

      def send_response(message)
        ensure_owner
        raise ClosedError.new("transport output is closed", phase: :write) if @closed || @writer_done

        ticket = @by_task[::Async::Task.current?]
        raise RequestExpired if ticket && !ticket.state[:expired] && clock >= ticket.deadline

        bytes = encode(message)
        raise RequestExpired if ticket && !ticket.state[:expired] && clock >= ticket.deadline

        if @output_bytes + bytes.bytesize > @max_output || @frames.length >= @max_requests * 4
          raise CapacityError.new("MCP output queue limit reached", phase: :write, delivery: :possibly_sent)
        end
        state = ticket&.state
        return nil if state && state[:cancelled]

        @frames << Frame.new(bytes: bytes, state: state)
        @output_bytes += bytes.bytesize
        @writable.signal
        nil
      rescue CapacityError, ProtocolError => error
        fail_transport(error)
        raise
      end

      def send_notification(method, params = nil, related_request_id: nil, **)
        return false if related_request_id && @by_id[related_request_id]&.state&.fetch(:cancelled)

        send_response({jsonrpc: "2.0", method: method, params: params}.compact)
        true
      end

      def send_request(*)
        raise UnsupportedFeatureError.new("server-initiated MCP requests are not supported by this transport", phase: :admission)
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def ensure_owner
        unless Process.pid == @pid && Thread.current.equal?(@thread) && Fiber.scheduler.equal?(@scheduler)
          raise ClosedError.new("MCP transport belongs to another scheduler, thread or process", phase: :admission)
        end
      end

      def child_task(&block)
        task = ::Async::Task.new(@parent) do
          block.call
        rescue ::Async::Cancel
          nil
        rescue Exception => error
          fail_transport(error)
        ensure
          @changed.signal
        end
        task
      end

      def fail_transport(error)
        @failure ||= error
        @stopping = true
        @changed.signal
      end

      def read_loop
        buffer = +"".b
        loop do
          break if @stopping

          chunk = @input.read_nonblock([16_384, @max_frame + 1 - buffer.bytesize].min, exception: false)
          if chunk == :wait_readable
            @scheduler.io_wait(@input, IO::READABLE)
            next
          end
          break unless chunk

          buffer << chunk.b
          while (ending = buffer.index("\n"))
            frame = buffer.slice!(0, ending + 1)
            raise CapacityError.new("MCP input frame limit reached", phase: :read) if frame.bytesize > @max_frame

            receive(frame)
            break if @stopping
          end
          raise CapacityError.new("MCP input frame limit reached", phase: :read) if buffer.bytesize >= @max_frame
          ::Async::Task.current.yield
        end
        receive(buffer) unless buffer.empty? || @stopping
      rescue IOError, SystemCallError => error
        raise TransportError.new("MCP input failed (#{error.class})", phase: :read), cause: nil
      ensure
        @input_done = true
        @changed.signal
      end

      def receive(frame)
        parsed = JSON.parse(frame, symbolize_names: true, max_nesting: 32)
        unless parsed.is_a?(Hash)
          send_response(@session.handle(nil))
          return
        end
        if parsed[:jsonrpc] == "2.0" && !parsed.key?(:id) && parsed[:method] == ::MCP::Methods::NOTIFICATIONS_CANCELLED
          @session.handle(parsed)
          id = parsed[:params][:requestId] if parsed[:params].is_a?(Hash)
          ticket = @by_id[id]
          stop_ticket(ticket) if ticket && ticket.request[:method] != ::MCP::Methods::INITIALIZE
          return
        end
        id = parsed[:id]
        if id && @by_id.key?(id)
          send_response(error_response(id, -32600, "Request ID is already in flight"))
          return
        end
        if @tickets.length >= @max_requests || @request_bytes + frame.bytesize > @max_request
          send_response(error_response(id, -32000, "MCP request capacity reached")) if id
          return
        end
        ticket = Ticket.new(request: parsed, bytes: frame.bytesize, deadline: clock + @request_timeout, state: {cancelled: false})
        ticket.task = ::Async::Task.new(@parent) { dispatch(ticket) }
        @tickets << ticket
        @waiting << ticket
        @by_id[id] = ticket if id
        @request_bytes += ticket.bytes
        @by_task[ticket.task] = ticket
        ticket.task.run
      rescue JSON::ParserError
        send_response(@session.handle_json("{"))
      end

      def dispatch(ticket)
        task = ::Async::Task.current
        task.with_timeout([ticket.deadline - clock, 0].max, RequestExpired) do
          loop do
            capacity = @session.era ? @concurrency : 1
            break if @waiting.first.equal?(ticket) && @active < capacity

            @changed.wait
          end
          @waiting.shift
          @active += 1
          ticket.active = true
          @changed.signal
          raise RequestExpired if clock >= ticket.deadline

          response = request_session(ticket.request).handle(ticket.request)
          raise RequestExpired if clock >= ticket.deadline
          if !@session.era && response.is_a?(Hash) && !response.key?(:error) &&
              (ticket.request[:method] == ::MCP::Methods::SERVER_DISCOVER || ::MCP::RequestEnvelope.modern?(ticket.request[:params]))
            @session.lock_era!(:modern)
          end
          send_response(response) if response && !ticket.state[:cancelled]
        end
      rescue RequestExpired
        ticket.state[:expired] = true
        if ticket.request[:id] && !ticket.state[:cancelled] && !@stopping
          send_response(error_response(ticket.request[:id], -32000, "MCP request deadline elapsed"))
        end
      rescue ::Async::Cancel
        nil
      rescue Exception => error
        fail_transport(error)
      ensure
        ticket.cancellation&.off_cancel(ticket.callback)
        release_ticket(ticket)
      end

      def release_ticket(ticket)
        return unless @tickets.delete(ticket)

        @active -= 1 if ticket.active
        @waiting.delete(ticket)
        @by_id.delete(ticket.request[:id]) if @by_id[ticket.request[:id]].equal?(ticket)
        @by_task.delete(ticket.task)
        @request_bytes -= ticket.bytes
        @changed.signal
      end

      def request_session(request)
        if @session.era == :modern || request[:method] == ::MCP::Methods::SERVER_DISCOVER || ::MCP::RequestEnvelope.modern?(request[:params])
          ModernSession.new(server: @server, transport: self, connection: @session, era: @session.era)
        else
          @session
        end
      end

      def bind_cancellation(id, token)
        ticket = @by_id[id]
        return unless ticket

        ticket.cancellation = token
        ticket.callback = token.on_cancel { stop_ticket(ticket) }
      end

      def stop_ticket(ticket, retry_cancel: false)
        was_cancelled = ticket.state[:cancelled]
        return if was_cancelled && !retry_cancel

        ticket.state[:cancelled] = true
        ticket.cancellation.cancel(reason: "Request stopped") if !was_cancelled && ticket.cancellation && !ticket.cancellation.cancelled?
        ticket.task.cancel if ticket.task && !ticket.task.finished?
      end

      def error_response(id, code, message)
        JsonRpcHandler.error_response(id: id, id_validation_pattern: JsonRpcHandler::DEFAULT_ALLOWED_ID_CHARACTERS,
          error: {code: code, message: message})
      end

      def encode(message)
        if message.is_a?(String)
          raise CapacityError.new("MCP output frame limit reached", phase: :write) if message.bytesize >= @max_output

          message = JSON.parse(message, max_nesting: 32)
        end
        measure(message)
        bytes = JSON.generate(message).b
        if bytes.bytesize + 1 > @max_output || bytes.include?("\n")
          raise CapacityError.new("MCP output frame limit reached", phase: :write)
        end
        (bytes + "\n").freeze
      rescue JSON::GeneratorError, JSON::ParserError, EncodingError
        raise ProtocolError.new("MCP response cannot be encoded", phase: :write), cause: nil
      end

      def measure(message)
        bytes, nodes = 1, 0 # Include the framing newline before allocating JSON.
        spend = lambda do |amount|
          bytes += amount
          raise CapacityError.new("MCP output frame limit reached", phase: :write) if bytes > @max_output
        end
        string = lambda do |value|
          unless value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?)
            raise ProtocolError.new("MCP response text must be UTF-8", phase: :write)
          end
          spend.call(2)
          value.each_byte do |byte|
            spend.call(case byte
            when 34, 92, 8, 9, 10, 12, 13 then 2
            when 0...32 then 6
            else 1
            end)
          end
        end
        visit = lambda do |value, depth|
          nodes += 1
          if depth > 32 || nodes > 65_536
            raise CapacityError.new("MCP response structure limit reached", phase: :write)
          end
          case value
          when String then string.call(value)
          when Symbol then string.call(value.to_s)
          when Integer then spend.call([1, value.bit_length].max + (value.negative? ? 1 : 0))
          when nil, true then spend.call(4)
          when false then spend.call(5)
          when Float
            raise ProtocolError.new("MCP response numbers must be finite", phase: :write) unless value.finite?
            spend.call(32)
          when Array
            spend.call(2 + [0, value.length - 1].max)
            value.each { |item| visit.call(item, depth + 1) }
          when Hash
            spend.call(2 + [0, value.length - 1].max + value.length)
            value.each do |key, item|
              unless key.is_a?(String) || key.is_a?(Symbol)
                raise ProtocolError.new("MCP response keys must be text", phase: :write)
              end
              visit.call(key, depth + 1)
              visit.call(item, depth + 1)
            end
          else raise ProtocolError.new("MCP response contains unsupported data", phase: :write)
          end
        end
        visit.call(message, 0)
      end

      def write_loop
        loop do
          if @frames.empty?
            break if @writer_done
            @writable.wait
            next
          end
          frame = @frames.shift
          begin
            next if frame.state && frame.state[:cancelled]

            deadline = clock + @write_timeout
            ::Async::Task.current.with_timeout(@write_timeout, WriteExpired) do
              offset = 0
              while offset < frame.bytes.bytesize
                raise WriteExpired if clock >= deadline

                written = @output.write_nonblock(frame.bytes.byteslice(offset, 16_384), exception: false)
                if written == :wait_writable
                  @scheduler.io_wait(@output, IO::WRITABLE)
                else
                  offset += written
                end
              end
            end
          ensure
            @output_bytes -= frame.bytes.bytesize
          end
        end
      rescue WriteExpired
        raise DeadlineExceeded.new("MCP output consumer exceeded its deadline", phase: :write, delivery: :possibly_sent)
      rescue IOError, SystemCallError => error
        raise TransportError.new("MCP output failed (#{error.class})", phase: :write, delivery: :possibly_sent), cause: nil
      end

      def retire
        deadline = clock + @cleanup_timeout
        errors = []
        @stopping = true
        cleanup_action(deadline, errors) { @reader.cancel if @reader && !@reader.finished? }
        @tickets.dup.each { |ticket| cleanup_action(deadline, errors) { stop_ticket(ticket, retry_cancel: true) } }
        @tickets.dup.each do |ticket|
          join_owned(ticket.task, deadline, errors)
          release_ticket(ticket) if ticket.task.finished?
        end
        @writer_done = true
        @writable.signal
        join_owned(@reader, deadline, errors)
        join_owned(@writer, deadline, errors)
        @closed = [@reader, @writer].compact.all?(&:finished?) && @tickets.empty?
        if @closed
          @frames.clear
          @output_bytes = 0
          restore_transport
        else
          errors << "MCP owned task retirement remains pending"
        end
        unless errors.empty?
          @failure ||= TransportError.new("MCP owned task did not retire", phase: :retire)
          attach_cleanup(@failure, errors)
        end
      end

      def attach_cleanup(error, details)
        if error.is_a?(Error)
          error.__send__(:attach_cleanup_errors, details)
        else
          error.extend(CleanupDetails)
          error.instance_variable_set(:@mcp_cleanup_errors, ((error.mcp_cleanup_errors || []) + details).freeze)
        end
      rescue FrozenError, TypeError
        nil
      end

      def cleanup_action(deadline, errors)
        yield
      rescue ::Async::Cancel => error
        @failure ||= error
        retry if clock < deadline
        errors << "MCP cleanup cancellation remains pending"
      rescue Exception => error
        errors << "MCP cleanup failed (#{error.class})"
      end

      def join_owned(task, deadline, errors)
        return if !task || task.finished?

        cleanup_action(deadline, errors) { task.wait(timeout: [deadline - clock, 0].max) }
        unless task.finished?
          cleanup_action(deadline, errors) { task.cancel unless task.finished? }
          cleanup_action(deadline, errors) { task.wait(timeout: [deadline - clock, 0].max) unless task.finished? }
        end
      end

      def restore_transport
        @server.transport = @previous_transport if @server.transport.equal?(self)
      end
    end
  end
end
