# frozen_string_literal: true

module LibTmux
  module MCP
    # One request-local budget covers target acquisition and the typed mutation.
    class Mutation
      def initialize(server:, arguments:, timeout:, cancel:, max_snapshot_bytes:)
        @server, @arguments, @cancel = server, arguments, cancel
        @deadline = clock + timeout
        @max_snapshot_bytes = max_snapshot_bytes
        bytes = 0
        visit = lambda do |value|
          case value
          when String then bytes += value.bytesize
          when Array then value.each { |item| visit.call(item) }
          when Hash then value.each { |key, item| visit.call(key); visit.call(item) }
          end
          raise CapacityError.new("MCP mutation input exceeds its byte limit", phase: :admission) if bytes > Catalog::MUTATION_BYTES
        end
        visit.call(arguments)
      end

      def call(name)
        case name
        when "tmux_create" then create
        when "tmux_send"
          target = resolve(@arguments.fetch("target"))
          input = @arguments.fetch("input")
          result = if input.fetch("type") == "text"
            dispatch { |budget| target.send_text(input.fetch("text"), **budget) }
          else
            dispatch { |budget| target.send_keys(*input.fetch("keys"), **budget) }
          end
          outcome(target, result).merge("completion" => "dispatch_only")
        when "tmux_close"
          target = resolve(@arguments.fetch("target"))
          outcome(target, dispatch { |budget| target.kill(**budget) })
        end
      end

      def delivery(error)
        @dispatched ? error.delivery : :not_sent
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def options
        raise Cancelled.new("MCP mutation was cancelled", phase: :admission) if @cancel.cancelled?

        remaining = @deadline - clock
        raise DeadlineExceeded.new("MCP mutation deadline elapsed", phase: :admission) unless remaining.positive?

        {timeout: remaining, cancel: @cancel}
      end

      def dispatch
        budget = options
        @dispatched = true
        yield budget
      end

      def resolve(reference)
        snapshot = @server.snapshot(**options, max_bytes: @max_snapshot_bytes, max_rows: 4096)
        unless reference.fetch("generation") == snapshot.binding_key
          raise TargetNotFoundError.new("target belongs to another server binding", phase: :admission)
        end
        kind = reference.fetch("kind")
        records = snapshot.public_send({"session" => :sessions, "window" => :windows, "pane" => :panes}.fetch(kind))
        record = records.find { |item| item.id == reference.fetch("id") }
        raise TargetNotFoundError.new("target is not present in this server binding", phase: :admission) unless record

        @server.public_send(kind, record.ref)
      end

      def create
        values = @arguments
        common = {command: values.fetch("argv"), cwd: values["cwd"], environment: values.fetch("environment", {})}
        created = case values.fetch("kind")
        when "session"
          dispatch do |budget|
            @server.new_session(name: values.fetch("name"), window_name: values["window_name"],
              width: values["width"], height: values["height"], receipt: true, **common, **budget)
          end
        when "window"
          parent = resolve(values.fetch("parent"))
          dispatch do |budget|
            parent.new_window(name: values.fetch("name"), index: values["index"],
              focus: values.fetch("focus", false), receipt: true, **common, **budget)
          end
        when "pane"
          parent = resolve(values.fetch("parent"))
          dispatch do |budget|
            parent.split(direction: values.fetch("direction").to_sym,
              size: values["size"], focus: values.fetch("focus", false), **common, **budget)
          end
        end
        entities = if created.is_a?(CreationReceipt)
          [created.entity, created.window, created.pane].uniq
        else
          [created]
        end
        {"entity" => reference(entities.first), "created" => entities.map { |entity| reference(entity) },
          "delivery" => "observed", "program_completion" => "unobserved"}
      end

      def reference(entity)
        {"generation" => entity.ref.binding_key, "kind" => entity.ref.kind.to_s, "id" => entity.id}
      end

      def outcome(target, result)
        {"target" => reference(target), "delivery" => result.delivery.to_s, "client_exit_status" => result.status.exitstatus}
      end
    end
    private_constant :Mutation
  end
end
