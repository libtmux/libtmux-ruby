# frozen_string_literal: true

module LibTmux
  class Workspace
    class ApplyResult
      Effect = Data.define(:step_id, :action, :outcome)
      attr_reader :completed_steps, :created_refs, :effects, :failed_step, :failed_action,
        :compensation, :cleanup_errors

      def initialize(completed_steps:, created_refs:, effects:, failed_step:, failed_action:,
        uncertain:, compensation:, cleanup_errors:)
        @completed_steps, @created_refs, @effects = completed_steps.dup.freeze, created_refs.dup.freeze, effects.dup.freeze
        @failed_step, @failed_action, @uncertain = failed_step, failed_action, uncertain
        @compensation, @cleanup_errors = compensation, cleanup_errors.map { |error| error.dup.freeze }.freeze
        freeze
      end
      private_class_method :new

      def success?
        failed_action.nil?
      end

      def uncertain?
        @uncertain
      end

      def inspect
        "#<#{self.class} success=#{success?} completed_steps=#{completed_steps.length} created_refs=#{created_refs.length} uncertain=#{uncertain?} compensation=#{compensation}>"
      end

      def to_h
        {"success" => success?, "completed_steps" => completed_steps,
          "created_refs" => created_refs.transform_values do |ref|
            {"binding_key" => ref.binding_key, "kind" => ref.kind.to_s, "id" => ref.id}
          end,
          "effects" => effects.map { |effect| {"step_id" => effect.step_id, "action" => effect.action.to_s, "outcome" => effect.outcome.to_s} },
          "failed_step" => failed_step, "failed_action" => failed_action&.to_s,
          "uncertain" => uncertain?, "compensation" => compensation.to_s, "cleanup_errors" => cleanup_errors}
      end
    end

    class ApplyError < LibTmux::Error
      attr_reader :result, :failure_class

      def initialize(result, failure)
        @result, @failure_class = result, failure.class.name.freeze
        delivery = result.uncertain? ? :possibly_sent : (result.effects.empty? ? :not_sent : :observed)
        super("workspace apply failed during #{result.failed_action} (#{failure_class})",
          phase: :apply, delivery: delivery, cleanup_errors: result.cleanup_errors)
      end
    end

    class ApplyExecution
      def initialize(plan, server, timeout, cancel, compensate)
        raise ArgumentError, "workspace apply requires a Server" unless server.is_a?(LibTmux::Server)
        raise ArgumentError, "workspace timeout must be finite" unless timeout.is_a?(Numeric) && timeout.finite?
        raise ArgumentError, "compensate must be boolean" unless [true, false].include?(compensate)
        if cancel && !(cancel.respond_to?(:reader) && cancel.respond_to?(:cancelled?))
          raise ArgumentError, "cancel must provide a cancellation reader and state"
        end
        @plan, @server, @cancel, @compensate = plan, server, cancel, compensate
        @deadline = clock + timeout
        @entities, @created, @completed, @effects, @cleanup_errors = {}, {}, [], [], []
        @compensation = :not_requested
        @action, @pending, @mutation = :preflight, false, false
      end

      def call
        failure = nil
        begin
          Thread.handle_interrupt(Exception => :never) do
            begin
              preflight
              @plan.steps.each do |step|
                @step = step
                perform(step)
                @completed << step.id
              end
              checkpoint
            rescue Exception => error
              failure = error
              @uncertain = @pending && @mutation && (!error.is_a?(LibTmux::Error) || error.delivery != :not_sent)
            ensure
              compensate if failure && @compensate
            end
          end
        rescue Exception => deferred
          failure ||= deferred
        end
        result = ApplyResult.__send__(:new, completed_steps: @completed, created_refs: @created,
          effects: @effects, failed_step: failure && @step&.id, failed_action: failure && @action,
          uncertain: !!@uncertain, compensation: @compensation, cleanup_errors: @cleanup_errors)
        raise ApplyError.new(result, failure), cause: nil if failure

        result
      end

      private

      def preflight
        snapshot = action(:capture_preconditions, mutation: false) { |options| @server.snapshot(**options) }
        expected = @plan.preconditions.fetch("binding_key")
        if expected && expected != snapshot.binding_key
          raise ConflictError.new("workspace plan belongs to another server binding", phase: :apply)
        end
        if snapshot.sessions.where(name: @plan.preconditions.fetch("session_name_absent")).exists?
          raise ConflictError.new("workspace creation requires an absent session name", phase: :apply)
        end
        @plan.steps.filter_map { |step| step.arguments["cwd"] }.uniq.each do |directory|
          unless File.directory?(directory) && File.executable?(directory)
            raise ConfigError.new("workspace directory is unavailable", expected: "existing accessible directory")
          end
        end
      end

      def perform(step)
        args = step.arguments
        target = @entities[step.target]
        case step.operation
        when :create_session
          action(:create_session) do |options|
            assignments = args.fetch("pane_environment").map { |name, value| "#{name}=#{value}" }
            receipt = @server.new_session(name: args.fetch("name"), window_name: args.fetch("window_name"),
              cwd: args.fetch("cwd"), environment: args.fetch("environment"),
              command: ["/usr/bin/env", "--", *assignments, "/bin/sh"], receipt: true, **options)
            remember("session", receipt.entity)
            remember(step.produces[1], receipt.window)
            remember(step.produces[2], receipt.pane)
          end
        when :create_window
          action(:create_window) do |options|
            receipt = target.new_window(name: args.fetch("name"), index: args.fetch("index"), command: ["/bin/sh"],
              cwd: args.fetch("cwd"), environment: args.fetch("environment"), focus: false, receipt: true, **options)
            remember(step.produces.first, receipt.window)
            remember(step.produces[1], receipt.pane)
          end
        when :split_pane
          action(:split_pane) do |options|
            pane = target.split(direction: args.fetch("direction").to_sym, size: args["size"], command: ["/bin/sh"],
              cwd: args.fetch("cwd"), environment: args.fetch("environment"), focus: false, **options)
            remember(step.produces.first, pane)
          end
        when :move_initial_window
          link = link_for(target)
          if link.index != args.fetch("index")
            action(:move_initial_window) { |options| link.move(session: @entities.fetch("session").ref, index: args.fetch("index"), **options) }
          end
        when :set_session_option, :set_window_option
          action(step.operation) { |options| target.options.set(args.fetch("name"), args.fetch("value"), **options) }
        when :unset_session_option, :unset_window_option
          action(step.operation) { |options| target.options.unset(args.fetch("name"), **options) }
        when :select_layout
          action(:select_layout) { |options| target.select_layout(args.fetch("layout"), **options) }
        when :send_command
          action(:insert_command_text, outcome: :dispatch_only) { |options| target.send_text(args.fetch("command"), **options) }
          action(:dispatch_command, outcome: :dispatch_only) { |options| target.send_keys("Enter", **options) }
        when :select_pane
          action(:select_pane) { |options| target.select(**options) }
        when :select_window
          link = link_for(target)
          action(:select_window) { |options| link.select(**options) }
        else
          raise UnsupportedFeatureError.new("workspace plan operation is unsupported", phase: :apply)
        end
      end

      def link_for(window)
        links = action(:acquire_window_link, mutation: false) { |options| @entities.fetch("session").list_window_links(**options) }
        only(links.select { |link| link.id == window.id })
      end

      def only(values)
        unless values.length == 1
          raise ConflictError.new("created workspace topology changed during apply", phase: :apply, delivery: :observed)
        end
        values.first
      end

      def remember(name, entity)
        @entities[name] = entity
        @created[name] = entity.ref
        entity
      end

      def action(name, mutation: true, outcome: :observed)
        @action, @pending, @mutation = name, false, mutation
        checkpoint
        raise Cancelled.new("workspace apply was cancelled", phase: :apply) if @cancel&.cancelled?
        remaining = @deadline - clock
        raise DeadlineExceeded.new("workspace apply deadline elapsed", phase: :apply) unless remaining.positive?

        @pending = true
        result = Thread.handle_interrupt(Exception => :on_blocking) { yield(timeout: remaining, cancel: @cancel) }
        @effects << ApplyResult::Effect.new(step_id: @step&.id, action: name, outcome: outcome) if mutation
        @pending = false
        checkpoint
        result
      end

      def compensate
        session = @entities["session"]
        @compensation = :nothing_owned
        return unless session

        deadline = clock + 0.5
        # A deferred interruption can be delivered by a core command checkpoint.
        # Retry only the positively owned session, within the same cleanup budget.
        2.times do
          begin
            remaining = deadline - clock
            raise DeadlineExceeded.new("workspace compensation deadline elapsed") unless remaining.positive?

            windows = @created.values.select { |ref| ref.kind == :window }
            panes = @created.values.select { |ref| ref.kind == :pane }
            session.kill(expected_windows: windows, expected_panes: panes, timeout: remaining)
            @compensation = :completed
            return
          rescue Exception => cleanup
            @compensation = :failed
            @cleanup_errors << "workspace compensation failed (#{cleanup.class})"
          end
        end
      end

      def checkpoint
        Thread.handle_interrupt(Exception => :immediate) { nil }
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
    private_constant :ApplyExecution
  end
end
