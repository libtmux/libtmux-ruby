# frozen_string_literal: true

require "libtmux/mcp/catalog"
require "libtmux/mcp/catalog_tool"
require "libtmux/mcp/mutations"
require "libtmux/mcp/observation"
require "libtmux/mcp/resources"

module LibTmux
  module MCP
    class Application
      CursorError = Class.new(LibTmux::Error)
      Capture = Data.define(:rows, :metadata, :limit, :expires, :bytes)
      private_constant :CursorError, :Capture

      attr_reader :tools

      def initialize(server:, endpoint_name:, enabled_tools: Catalog::READ_ONLY,
        max_captures: 16, max_capture_bytes: 1 << 23, capture_ttl: 30,
        request_timeout: 5, max_response_bytes: 1 << 20)
        raise ArgumentError, "MCP requires an application-owned Async server facade" unless server.is_a?(LibTmux::Async::Server)
        unless endpoint_name.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(endpoint_name)
          raise ArgumentError, "endpoint_name must be a public endpoint alias"
        end
        unless enabled_tools.is_a?(Array) && (enabled_tools - Catalog::NAMES).empty?
          raise ArgumentError, "enabled_tools must name implemented catalog tools"
        end
        unless [max_captures, max_capture_bytes, max_response_bytes].all? { |n| n.is_a?(Integer) && n.positive? }
          raise ArgumentError, "MCP capacity limits must be positive Integers"
        end
        if (enabled_tools & Catalog::MUTATIONS).any? && max_response_bytes < Catalog::MIN_MUTATION_RESPONSE_BYTES
          raise ArgumentError, "MCP mutation response capacity must be at least 4096 bytes"
        end
        unless [capture_ttl, request_timeout].all? { |n| n.is_a?(Numeric) && n.finite? && n.positive? }
          raise ArgumentError, "MCP deadlines must be positive and finite"
        end
        @server, @endpoint = server, endpoint_name.dup.freeze
        @enabled = Catalog::NAMES.select { |name| enabled_tools.include?(name) }.freeze
        @limits = {"max_captures" => max_captures, "max_capture_bytes" => max_capture_bytes,
          "capture_ttl_seconds" => capture_ttl, "request_timeout_seconds" => request_timeout,
          "max_response_bytes" => max_response_bytes, "max_mutation_bytes" => Catalog::MUTATION_BYTES,
          "max_observers" => max_captures,
          "min_mutation_response_bytes" => Catalog::MIN_MUTATION_RESPONSE_BYTES}.freeze
        @thread, @pid, @scheduler = Thread.current, Process.pid, Fiber.scheduler
        @captures, @retained_bytes = {}, 0
        @observers, @retiring = [], []
        @calls, @calls_changed = {}, ::Async::Notification.new
        application = self
        @tools = @enabled.map do |name|
          CatalogTool.define(name: name, description: Catalog.description(name),
            input_schema: Catalog.input(name), output_schema: Catalog.output(name),
            annotations: {read_only_hint: false, destructive_hint: Catalog::MUTATIONS.include?(name), idempotent_hint: false, open_world_hint: false}) do |server_context: nil, **arguments|
            application.call(name, arguments, cancellation: server_context&.cancellation)
          end
        end.freeze
        @by_name = @tools.to_h { |tool| [tool.name_value, tool] }.freeze
      end

      def sdk_server
        ::MCP::Server.new(name: "libtmux", version: VERSION, tools: tools,
          instructions: "Use discovery before operations. Captured metadata is interval evidence, not an atomic snapshot.",
          configuration: ::MCP::Configuration.new(validate_tool_call_arguments: false, validate_tool_call_results: true),
          capabilities: {tools: {listChanged: false}}, ttl_ms: 0, cache_scope: "private").tap do |sdk|
          Resources.new(application: self, endpoint_name: @endpoint, enabled_tools: @enabled,
            max_response_bytes: @limits.fetch("max_response_bytes")).install(sdk)
        end
      end

      def call(name, arguments = {}, cancellation: nil)
        unless Process.pid == @pid && Thread.current.equal?(@thread) && Fiber.scheduler.equal?(@scheduler)
          raise ClosedError.new("MCP application belongs to another scheduler", phase: :admission)
        end
        return failure_response("policy_denied", "The configured policy denies this operation.") unless @enabled.include?(name)
        return failure_response("closed", "The application is closed.") if @closed

        tool = @by_name.fetch(name)
        tool.input_schema_value
        tool.output_schema_value
        wire = JSON.generate(arguments)
        raise CapacityError.new("MCP input exceeds its byte limit", phase: :admission) if wire.bytesize > 1 << 20
        arguments = JSON.parse(wire, max_nesting: 68, allow_nan: false, allow_duplicate_key: false)
        tool.input_schema_value.validate_arguments(arguments)
        token = Internal::Cancellation.new
        @calls[token] = ::Async::Task.current
        callback = cancellation&.on_cancel { token.cancel }
        raise Cancelled.new("MCP request was cancelled", phase: :admission) if token.cancelled?

        result = case name
        when "tmux_capabilities" then capabilities(token)
        when "tmux_snapshot" then snapshot(arguments, token)
        when "tmux_capture" then capture_screen(arguments, token)
        when "tmux_wait" then wait_for_observation(arguments, token)
        else
          mutation = Mutation.new(server: @server, arguments: arguments, timeout: @limits.fetch("request_timeout_seconds"),
            cancel: token, max_snapshot_bytes: [@limits.fetch("max_capture_bytes"), 1 << 20].min)
          mutation.call(name)
        end
        structured = {"ok" => true, "data" => result}
        validate_response_size(structured)
        tool.output_schema_value.validate_result(structured)
        ::MCP::Tool::Response.new([{type: "text", text: "#{name} completed; structuredContent contains the result."}], structured_content: structured)
      rescue ::MCP::Tool::InputSchema::ValidationError, JSON::JSONError, ArgumentError
        failure_response("invalid_input", "Input does not match the operation schema.")
      rescue CursorError, Observation::StaleCursor
        failure_response("stale_cursor", "The cursor is unknown, expired, or outside its captured result.")
      rescue LibTmux::Error => error
        code = {InvalidFilterError => "invalid_filter", FieldDecodeError => "decode_error",
          IncompleteSnapshotError => "incomplete_snapshot", Cancelled => "cancelled",
          DeadlineExceeded => "deadline", CapacityError => "capacity", TargetNotFoundError => "stale_target",
          CommandError => "command_failed", UnsupportedFeatureError => "unsupported", ClosedError => "closed",
          Observation::LostObservation => "observation_lost"}.fetch(error.class, "transport_error")
        delivery = mutation ? mutation.delivery(error) : error.delivery
        effects = if Catalog::MUTATIONS.include?(name)
          created = result && result["created"]
          {"state" => created ? "known" : delivery == :not_sent ? "none" : "unknown", "created" => created || []}
        end
        failure_response(code, "The operation could not establish its requested result.", delivery.to_s, effects: effects)
      ensure
        begin
          cancellation&.off_cancel(callback) if callback
        ensure
          begin
            token&.close
          ensure
            @calls.delete(token) if token
            @calls_changed.signal if token
          end
        end
      end

      def inspect
        "#<#{self.class} enabled_tools=#{@enabled.length} retained_captures=#{@captures.length}>"
      end

      def close
        unless Process.pid == @pid && Thread.current.equal?(@thread) && Fiber.scheduler.equal?(@scheduler)
          raise ClosedError.new("MCP application belongs to another scheduler", phase: :retire)
        end
        if @calls.value?(::Async::Task.current)
          raise ClosedError.new("cannot close an MCP application from its active request", phase: :retire)
        end
        @closed = true
        errors = []
        interrupted = nil
        deadline = clock + 0.5
        @calls.keys.each do |token|
          begin
            token.cancel
          rescue Exception => error
            interrupted ||= error if error.is_a?(::Async::Cancel)
            errors << "request cancellation failed (#{error.class})"
          end
        end
        until @calls.empty? || clock >= deadline
          begin
            ::Async::Task.current.with_timeout(deadline - clock) { @calls_changed.wait }
          rescue ::Async::Cancel => error
            interrupted ||= error
          rescue ::Async::TimeoutError
            break
          end
        end
        errors << "admitted requests remain active" unless @calls.empty?
        @captures.keys.each do |key|
          begin
            evict(key)
          rescue Exception => error
            interrupted ||= error if error.is_a?(::Async::Cancel)
            errors << "capture retirement failed (#{error.class})"
          end
        end
        @retiring.dup.each do |resource|
          begin
            resource.is_a?(Observation) ? resource.close(timeout: [deadline - clock, 0].max) : resource.close
            @observers.delete(resource)
            @retiring.delete(resource)
          rescue Exception => error
            interrupted ||= error if error.is_a?(::Async::Cancel)
            errors << "observation retirement failed (#{error.class})"
          end
        end
        if interrupted
          ProcessIdentity.attach_cleanup(interrupted, errors) unless errors.empty?
          raise interrupted
        end
        raise TransportError.new("MCP application cleanup remains pending", phase: :retire, cleanup_errors: errors) unless errors.empty?

        nil
      end

      private

      def observation(arguments, cancel)
        if !@retiring.empty? || @observers.length >= @limits.fetch("max_observers")
          raise CapacityError.new("observation admission is full or retiring", phase: :admission)
        end
        observer = Observation.new(server: @server, arguments: arguments, timeout: @limits.fetch("request_timeout_seconds"),
          cancel: cancel, max_snapshot_bytes: [@limits.fetch("max_capture_bytes"), 1 << 20].min)
        @observers << observer
        observer
      end

      def capture_screen(arguments, cancel)
        prune
        previous = arguments["cursor"] && @captures[arguments.fetch("cursor")]
        if arguments["cursor"] && !previous.is_a?(Observation::Capture)
          raise CursorError, "screen cursor capture is unavailable"
        end
        observer = observation(arguments, cancel)
        result, entry = observer.capture(previous: previous, expires: clock + @limits.fetch("capture_ttl_seconds"))
        @retiring << entry if entry
        validate_response_size({"ok" => true, "data" => result})
        if entry
          raise ClosedError.new("MCP application closed during capture", phase: :read) if @closed
          raise CapacityError.new("screen capture exceeds retention bytes", delivery: :observed) if entry.bytes > @limits.fetch("max_capture_bytes")

          while @captures.length >= @limits.fetch("max_captures") || @retained_bytes + entry.bytes > @limits.fetch("max_capture_bytes")
            evict(@captures.keys.first)
          end
          @captures[entry.capture_id] = entry
          @retained_bytes += entry.bytes
          @retiring.delete(entry)
          entry = nil
        end
        result
      ensure
        retire_observation(observer, entry)
      end

      def wait_for_observation(arguments, cancel)
        observer = observation(arguments, cancel)
        observer.wait
      ensure
        retire_observation(observer)
      end

      def retire_observation(observer, entry = nil)
        primary = $!
        errors = []
        [observer, entry].compact.each do |resource|
          begin
            resource.is_a?(Observation) ? resource.close(timeout: resource.cleanup_remaining) : resource.close
            @observers.delete(resource)
            @retiring.delete(resource)
          rescue Exception => error
            errors << "observation cleanup failed (#{error.class})"
            @retiring << resource unless @retiring.include?(resource)
          end
        end
        return if errors.empty?

        if primary.is_a?(LibTmux::Error)
          primary.__send__(:attach_cleanup_errors, errors)
        elsif primary
          ProcessIdentity.attach_cleanup(primary, errors)
        elsif !primary
          raise TransportError.new("observation cleanup remains pending", phase: :retire, cleanup_errors: errors)
        end
      end

      def acquire(cancel)
        @server.snapshot(timeout: @limits.fetch("request_timeout_seconds"), cancel: cancel,
          clients: true, max_bytes: [@limits.fetch("max_capture_bytes"), 1 << 20].min, max_rows: 4096)
      end

      def identity(snapshot)
        {"generation" => snapshot.binding_key, "pid" => snapshot.server_info.fetch(:pid),
          "start_time" => snapshot.server_info.fetch(:start_time), "tmux_version" => snapshot.server_info.fetch(:version)}
      end

      def capabilities(cancel)
        snapshot = acquire(cancel)
        {"endpoint" => @endpoint, "server_identity" => identity(snapshot), "enabled_tools" => @enabled,
          "criteria_schema" => FilterExpr.json_schema, "limits" => @limits,
          "owns_daemon" => false, "resource_subscriptions" => false,
          "observation" => Observation.capabilities(snapshot.server_info.fetch(:version))}
      end

      def snapshot(arguments, cancel)
        prune
        if arguments["cursor"]
          key, position = arguments.fetch("cursor").split(":", 2)
          capture = @captures.fetch(key) { raise CursorError, "cursor capture is unavailable" }
          raise CursorError, "cursor has another capture kind" unless capture.is_a?(Capture)
          offset = Integer(position, 10)
          raise CursorError, "cursor offset is outside the capture" unless offset.positive? && offset < capture.rows.length
          return page(key, capture, offset)
        end
        entity = arguments.fetch("entity").to_sym
        expression = if arguments["criteria"]
          FilterExpr.from_json(JSON.generate(arguments.fetch("criteria")))
        else
          FilterExpr.build(entity)
        end
        raise InvalidFilterError, "criteria entity does not match acquisition" unless expression.entity == entity

        snapshot = acquire(cancel)
        selection = snapshot.public_send({session: :sessions, window: :windows, pane: :panes,
          window_link: :window_links, client: :clients}.fetch(entity)).where(expression)
        bytes = 0
        rows = selection.map do |record|
          fields = Internal::Catalog.entity(entity).fields.values.to_h { |field| [field.wire_name, record.public_send(field.name)] }
          reference = if entity == :client
            nil
          else
            ref = record.ref
            {"generation" => ref.binding_key, "kind" => ref.kind.to_s, "id" => ref.id}.tap do |value|
              if entity == :window_link
                value["session_id"], value["index"] = ref.session_id, ref.index
              end
            end
          end
          row = {"kind" => entity.to_s, "fields" => fields, "ref" => reference}
          bytes += JSON.generate(row).bytesize
          raise CapacityError.new("captured records exceed retention bytes", delivery: :observed) if bytes > @limits.fetch("max_capture_bytes")
          row
        end
        metadata = {"capture_id" => snapshot.capture_id, "server_identity" => identity(snapshot),
          "entity" => entity.to_s, "coverage" => Internal::Catalog.kinds.to_h { |kind| [kind.to_s, "complete"] },
          "interval" => {"clock" => "monotonic_seconds", "started" => snapshot.started_at,
            "finished" => snapshot.finished_at, "reads" => snapshot.reads.length}}
        bytes += JSON.generate(metadata).bytesize
        raise CapacityError.new("capture exceeds retention bytes", delivery: :observed) if bytes > @limits.fetch("max_capture_bytes")
        key = SecureRandom.hex(16)
        capture = Capture.new(rows: freeze_tree(rows), metadata: freeze_tree(metadata), limit: arguments.fetch("limit", 50),
          expires: clock + @limits.fetch("capture_ttl_seconds"), bytes: bytes)
        first_page = page(key, capture, 0)
        validate_response_size({"ok" => true, "data" => first_page})
        raise ClosedError.new("MCP application closed during capture", phase: :read) if @closed
        while @captures.length >= @limits.fetch("max_captures") || @retained_bytes + bytes > @limits.fetch("max_capture_bytes")
          evict(@captures.keys.first)
        end
        @captures[key] = capture
        @retained_bytes += bytes
        first_page
      end

      def validate_response_size(structured)
        if JSON.generate(structured).bytesize > @limits.fetch("max_response_bytes")
          raise CapacityError.new("MCP response exceeds its byte limit", phase: :read, delivery: :observed)
        end
      end

      def page(key, capture, offset)
        items = capture.rows.slice(offset, capture.limit) || []
        next_position = offset + items.length
        capture.metadata.merge("items" => items, "truncated" => next_position < capture.rows.length).tap do |result|
          result["next_cursor"] = "#{key}:#{next_position}" if next_position < capture.rows.length
        end
      end

      def prune
        @captures.keys.each { |key| evict(key) if @captures.fetch(key).expires <= clock }
      end

      def evict(key)
        entry = @captures.fetch(key)
        entry.close if entry.respond_to?(:close)
        @captures.delete(key)
        @retained_bytes -= entry.bytes
      end

      def freeze_tree(value)
        case value
        when Hash then value.each { |key, child| key.freeze; freeze_tree(child) }
        when Array then value.each { |child| freeze_tree(child) }
        end
        value.freeze
      end

      def failure_response(code, message, delivery = "not_sent", effects: nil)
        details = {"code" => code, "message" => message, "delivery" => delivery}
        details["effects"] = effects if effects
        ::MCP::Tool::Response.new([{type: "text", text: message}], error: true,
          structured_content: {"ok" => false, "error" => details})
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
