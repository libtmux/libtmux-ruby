# frozen_string_literal: true

module LibTmux
  class Workspace
    class Plan
      Step = Data.define(:id, :operation, :target, :arguments, :produces, :effect) do
        def inspect
          "#<#{self.class} id=#{id} operation=#{operation} effect=#{effect}>"
        end
      end
      attr_reader :mode, :preconditions, :steps

      def initialize(workspace, snapshot: nil)
        unless snapshot.nil? || snapshot.is_a?(LibTmux::Snapshot)
          raise ArgumentError, "workspace planning requires a captured Snapshot"
        end
        @configuration = workspace.to_h
        name = @configuration.fetch("session_name")
        if snapshot && snapshot.sessions.where(name: name).exists?
          raise ConflictError.new("workspace creation requires an absent session name", phase: :plan)
        end
        @mode = snapshot ? :captured_create : :offline_create
        @preconditions = immutable({"session_name_absent" => name,
          "binding_key" => snapshot&.binding_key, "capture_id" => snapshot&.capture_id})
        @steps = []
        build
        @steps.freeze
        freeze
      end

      def to_h
        {"profile" => PROFILE, "version" => CONFIG_VERSION, "mode" => mode.to_s,
          "preconditions" => preconditions,
          "steps" => steps.map do |step|
            {"id" => step.id, "operation" => step.operation.to_s, "target" => step.target,
              "arguments" => step.arguments, "produces" => step.produces, "effect" => step.effect.to_s}
          end}
      end

      def inspect
        "#<#{self.class} mode=#{mode} steps=#{steps.length}>"
      end

      def apply(server:, timeout: 5.0, cancel: nil, compensate: false)
        ApplyExecution.new(self, server, timeout, cancel, compensate).call
      end

      private

      def build
        windows = @configuration.fetch("windows")
        initial = windows.first.fetch("panes").first
        add(:create_session, "session", {"name" => @configuration.fetch("session_name"),
          "window_name" => windows.first.fetch("window_name"), "cwd" => initial.fetch("start_directory"),
          "session_cwd" => @configuration.fetch("start_directory"),
          "environment" => @configuration.fetch("environment"), "pane_environment" => initial.fetch("environment")},
          produces: ["session", "window:0", "pane:0:0"], effect: :creation)
        add(:set_session_option, "session", {"name" => "renumber-windows", "value" => false})
        add(:set_window_option, "window:0", {"name" => "synchronize-panes", "value" => false})
        add(:move_initial_window, "window:0", {"session" => "session", "index" => windows.first.fetch("window_index")})
        @configuration.fetch("options").sort.each do |name, value|
          add(:set_session_option, "session", {"name" => name, "value" => value}) unless name == "renumber-windows"
        end
        windows.each_with_index do |window, position|
          unless position.zero?
            pane = window.fetch("panes").first
            add(:create_window, "session", {"name" => window.fetch("window_name"), "index" => window.fetch("window_index"),
              "cwd" => pane.fetch("start_directory"), "environment" => pane.fetch("environment"), "focus" => false},
              produces: ["window:#{position}", "pane:#{position}:0"], effect: :creation)
            add(:set_window_option, "window:#{position}", {"name" => "synchronize-panes", "value" => false})
          end
          window.fetch("panes").each_with_index do |pane, pane_position|
            next if pane_position.zero?
            add(:split_pane, "pane:#{position}:#{pane_position - 1}",
              {"direction" => pane.fetch("split"), "size" => pane["size"], "cwd" => pane.fetch("start_directory"),
                "environment" => pane.fetch("environment"), "focus" => false},
              produces: ["pane:#{position}:#{pane_position}"], effect: :creation)
          end
        end
        windows.each_with_index do |window, position|
          window.fetch("options").sort.each do |name, value|
            next if name == "synchronize-panes"
            add(:set_window_option, "window:#{position}", {"name" => name, "value" => value})
          end
          add(:select_layout, "window:#{position}", {"layout" => window.fetch("layout")}) if window["layout"]
          window.fetch("panes").each_with_index do |pane, pane_position|
            (pane.fetch("shell_command_before") + pane.fetch("shell_command")).each do |command|
              add(:send_command, "pane:#{position}:#{pane_position}", {"command" => command}, effect: :dispatch_only)
            end
          end
          if window.fetch("options").key?("synchronize-panes")
            add(:set_window_option, "window:#{position}", {"name" => "synchronize-panes", "value" => window.fetch("options").fetch("synchronize-panes")})
          else
            add(:unset_window_option, "window:#{position}", {"name" => "synchronize-panes"})
          end
          pane_focus = window.fetch("panes").index { |pane| pane.fetch("focus") }
          add(:select_pane, "pane:#{position}:#{pane_focus}", {})
        end
        selected = windows.index { |window| window.fetch("focus") }
        add(:select_window, "window:#{selected}", {"session" => "session"})
        if @configuration.fetch("options").key?("renumber-windows")
          add(:set_session_option, "session", {"name" => "renumber-windows", "value" => @configuration.fetch("options").fetch("renumber-windows")})
        else
          add(:unset_session_option, "session", {"name" => "renumber-windows"})
        end
      end

      def add(operation, target, arguments, produces: [], effect: :configuration)
        @steps << Step.new(id: @steps.length + 1, operation: operation, target: target.freeze,
          arguments: immutable(arguments), produces: immutable(produces), effect: effect)
      end

      def immutable(value)
        case value
        when Hash then value.to_h { |key, child| [key.dup.freeze, immutable(child)] }.freeze
        when Array then value.map { |child| immutable(child) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end
  end
end
