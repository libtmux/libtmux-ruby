# frozen_string_literal: true

require_relative "snapshot"
require_relative "metadata"

module LibTmux
  module Internal
    class Capture
      def initialize(server, binding_key:)
        @server = server
        @binding_key = binding_key.dup.freeze
      end

      def call(timeout: 5.0, cancel: nil, clients: false, max_bytes: 1 << 20,
        max_rows: 10_000, max_field_bytes: 1 << 16)
        unless timeout.is_a?(Numeric) && timeout.finite?
          raise ArgumentError, "capture timeout must be finite"
        end
        unless [max_bytes, max_rows, max_field_bytes].all? { |value| value.is_a?(Integer) && value.positive? }
          raise ArgumentError, "capture limits must be positive integers"
        end
        unless clients == true || clients == false
          raise ArgumentError, "clients must be a Boolean"
        end
        if cancel && !(cancel.respond_to?(:cancelled?) && cancel.respond_to?(:reader))
          raise ArgumentError, "cancel must be a cancellation token"
        end
        started_at = monotonic
        budget = {deadline: started_at + timeout, cancel: cancel, max_bytes: max_bytes,
                  max_rows: max_rows, max_field_bytes: max_field_bytes, bytes: 0, rows: 0, reads: []}
        server_info = acquire_server_info(budget)
        2.times do |attempt|
          rows = acquire_rows(budget, attempt + 1, clients)
          check_budget(budget)
          begin
            snapshot = Snapshot.__send__(:new, rows: rows, binding_key: @binding_key,
              started_at: started_at, finished_at: monotonic, reads: budget.fetch(:reads), server_info: server_info)
            check_budget(budget)
            return snapshot
          rescue InconsistentSnapshotError
            raise if attempt == 1
            check_budget(budget)
          end
        end
      end

      private

      def acquire_server_info(budget)
        rows = read(budget, :server, 1, ["display-message", "-p", framing(%w[version pid start_time])], 3)
        unless rows.length == 1
          raise ProtocolError.new("invalid capture server metadata", delivery: :observed, phase: :capture)
        end
        version, pid, start_time = rows.first
        version = version.dup.force_encoding(Encoding::UTF_8)
        match = /\A(?:next-)?([0-9]+)\.([0-9]+)([a-z]?)(?:-[A-Za-z0-9.-]+)?\z/.match(version) if version.valid_encoding?
        unless match
          raise UnsupportedFeatureError.new("unrecognized tmux version for capture", delivery: :observed, phase: :capture)
        end
        supported = ([match[1].to_i, match[2].to_i, match[3]] <=> [3, 2, "a"]) >= 0
        unless supported
          raise UnsupportedFeatureError.new("captured metadata requires tmux 3.2a or newer", delivery: :observed, phase: :capture)
        end
        unless pid.match?(/\A[1-9][0-9]{0,9}\z/n) && start_time.match?(/\A-?[0-9]{1,19}\z/n)
          raise ProtocolError.new("invalid capture server identity metadata", delivery: :observed, phase: :capture)
        end
        {version: version, pid: Integer(pid, 10), start_time: Integer(start_time, 10),
         capabilities: {metadata: :byte_counted, field_baseline: "3.2a"}}
      end

      def acquire_rows(budget, attempt, clients)
        sessions = catalog_read(budget, :session, attempt, ["list-sessions"])
        if sessions.empty?
          # tmux has no windows or panes without a session. Their list commands
          # nevertheless require a default target, so the complete empty root
          # supplies this evidence without treating command failures as emptiness.
          rows = {session: sessions, window: [], window_link: [], pane: []}
          rows[:client] = [] if clients
          return rows
        end
        window_fields = Catalog.entity(:window).fields.values
        link_fields = Catalog.entity(:window_link).fields.values
        combined = read(budget, :window_link, attempt,
          ["list-windows", "-a", "-F", framing((window_fields + link_fields).map(&:format))],
          window_fields.length + link_fields.length)
        windows = []
        links = []
        combined.each do |row|
          windows << window_fields.map(&:name).zip(row.take(window_fields.length)).to_h
          links << link_fields.map(&:name).zip(row.drop(window_fields.length)).to_h
        end
        rows = {session: sessions, window: windows, window_link: links,
                pane: catalog_read(budget, :pane, attempt, ["list-panes", "-a"])}
        rows[:client] = catalog_read(budget, :client, attempt, ["list-clients"]) if clients
        rows
      end

      def catalog_read(budget, kind, attempt, command)
        fields = Catalog.entity(kind).fields.values
        read(budget, kind, attempt, command + ["-F", framing(fields.map(&:format))], fields.length)
          .map { |row| fields.map(&:name).zip(row).to_h }
      end

      def framing(formats)
        Metadata.format(formats)
      end

      def read(budget, source, attempt, argv, field_count)
        started_at = monotonic
        remaining = check_budget(budget)
        result = @server.__send__(:execute_typed, argv, timeout: remaining, cancel: budget.fetch(:cancel))
        finished_at = monotonic
        budget[:bytes] += result.stdout.bytesize
        capacity("capture exceeds its total byte limit") if budget.fetch(:bytes) > budget.fetch(:max_bytes)
        remaining_rows = budget.fetch(:max_rows) - budget.fetch(:rows)
        capacity("capture exceeds its total row limit") if remaining_rows <= 0 && !result.stdout.empty?
        rows = Metadata.decode(result.stdout, fields: field_count, quoted: true, max_bytes: budget.fetch(:max_bytes),
          max_rows: [remaining_rows, 1].max, max_field_bytes: budget.fetch(:max_field_bytes))
        budget[:rows] += rows.length
        budget.fetch(:reads) << {source: source, attempt: attempt, started_at: started_at,
                                finished_at: finished_at, bytes: result.stdout.bytesize, rows: rows.length}
        rows
      end

      def check_budget(budget)
        delivery = budget.fetch(:reads).empty? ? :not_sent : :observed
        if budget.fetch(:cancel)&.cancelled?
          raise Cancelled.new("capture cancelled", delivery: delivery, phase: :capture)
        end
        remaining = budget.fetch(:deadline) - monotonic
        unless remaining.positive?
          raise DeadlineExceeded.new("capture exceeded its deadline", delivery: delivery, phase: :capture)
        end
        remaining
      end

      def capacity(message)
        raise CapacityError.new(message, delivery: :observed, phase: :capture)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
