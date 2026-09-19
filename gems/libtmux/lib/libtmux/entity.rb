# frozen_string_literal: true

module LibTmux
  # IDs printed by the creation command itself, before later topology changes.
  # A receipt proves creation, not continued ownership or current membership.
  class CreationReceipt
    attr_reader :entity, :window, :pane, :result

    def initialize(entity:, window:, pane:, result:)
      @entity, @window, @pane, @result = entity, window, pane, result
      freeze
    end
    private_class_method :new

    def inspect
      "#<#{self.class} entity=#{entity.id} window=#{window.id} pane=#{pane.id}>"
    end
  end

  # A target belongs to one open server binding; names never identify it.
  class EntityRef
    attr_reader :binding_key, :kind, :id, :session_id, :index

    def initialize(binding_key:, kind:, id:, session_id: nil, index: nil)
      prefix = {session: "$", window: "@", pane: "%", window_link: "@"}.fetch(kind)
      unless id.is_a?(String) && id.match?(/\A#{Regexp.escape(prefix)}\d+\z/)
        raise ProtocolError.new("tmux returned an invalid #{kind} ID", delivery: :observed, phase: :decode)
      end
      @binding_key = binding_key.dup.freeze
      @kind = kind
      @id = id.dup.freeze
      if kind == :window_link
        unless session_id.is_a?(String) && session_id.match?(/\A\$\d+\z/) && index.is_a?(Integer) && index >= 0
          raise ProtocolError.new("tmux returned invalid window link context", delivery: :observed, phase: :decode)
        end
        @session_id = session_id.dup.freeze
        @index = index
      elsif session_id || index
        raise ArgumentError, "only window links have session and index context"
      end
      freeze
    end
    private_class_method :new

    def ==(other)
      other.is_a?(EntityRef) && [binding_key, kind, id, session_id, index] ==
        [other.binding_key, other.kind, other.id, other.session_id, other.index]
    end
    alias eql? ==

    def hash
      [binding_key, kind, id, session_id, index].hash
    end

    def inspect
      "#<#{self.class} #{kind} #{id}>"
    end
  end

  class Entity
    attr_reader :server, :ref

    def initialize(server, ref)
      @server = server
      @ref = ref
      freeze
    end
    private_class_method :new

    def id
      ref.id
    end

    def snapshot(**options)
      server.snapshot(**options).resolve(ref)
    end

    def ==(other)
      other.is_a?(Entity) && ref == other.ref
    end
    alias eql? ==

    def hash
      ref.hash
    end

    def kill(timeout: 5.0, cancel: nil)
      server.__send__(:execute_typed, ["kill-#{ref.kind}", "-t", target], timeout: timeout, cancel: cancel)
    end

    def inspect
      "#<#{self.class} #{id}>"
    end

    private

    def target
      server.__send__(:target, ref, ref.kind)
    end
  end

  class Session < Entity
    def new_window(name:, command:, index: nil, cwd: nil, environment: {}, focus: false, receipt: false, timeout: 5.0, cancel: nil)
      server.__send__(:create_window, ref, name: name, command: command, index: index,
        cwd: cwd, environment: environment, focus: focus, receipt: receipt, timeout: timeout, cancel: cancel)
    end

    def list_windows(timeout: 5.0, cancel: nil)
      server.__send__(:list_entities, :window, ["-t", target], timeout: timeout, cancel: cancel)
    end

    def list_panes(timeout: 5.0, cancel: nil)
      server.__send__(:list_entities, :pane, ["-s", "-t", target], timeout: timeout, cancel: cancel)
    end
  end

  class Window < Entity
    def list_panes(timeout: 5.0, cancel: nil)
      server.__send__(:list_entities, :pane, ["-t", target], timeout: timeout, cancel: cancel)
    end

    def split(direction:, command:, size: nil, cwd: nil, environment: {}, focus: false, timeout: 5.0, cancel: nil)
      server.__send__(:split_window, ref, direction: direction, command: command, size: size,
        cwd: cwd, environment: environment, focus: focus, timeout: timeout, cancel: cancel)
    end

    def select_layout(layout, timeout: 5.0, cancel: nil)
      unless layout.is_a?(String) || layout.is_a?(Symbol)
        raise ArgumentError, "layout must be a String or Symbol"
      end
      value = layout.is_a?(Symbol) ? layout.to_s.tr("_", "-") : layout
      server.__send__(:execute_typed, ["select-layout", "-t", target, "--", value], timeout: timeout, cancel: cancel)
    end
  end

  class Pane < Entity
    def split(direction:, command:, size: nil, cwd: nil, environment: {}, focus: false, timeout: 5.0, cancel: nil)
      server.__send__(:split_window, ref, direction: direction, command: command, size: size,
        cwd: cwd, environment: environment, focus: focus, timeout: timeout, cancel: cancel)
    end

    def capture(start: nil, finish: nil, join: false, escapes: false, escape_bytes: false, preserve_trailing: false,
      trim_trailing: false, alternate: false, mode_screen: false, pending: false, timeout: 5.0, cancel: nil)
      budget = server.__send__(:operation_budget, timeout, cancel)
      if [alternate, mode_screen, pending].count { |value| value } > 1
        raise ArgumentError, "alternate, mode_screen and pending captures are mutually exclusive"
      end
      arguments = ["capture-pane", "-p", "-t", target]
      {"-S" => start, "-E" => finish}.each do |flag, value|
        next if value.nil?
        raise ArgumentError, "capture ranges must be integers or '-'" unless value.is_a?(Integer) || value == "-"

        arguments.concat([flag, value.to_s])
      end
      {"T" => trim_trailing, "M" => mode_screen}.each do |flag, enabled|
        next unless enabled

        server.__send__(:require_command_flag, "capture-pane", flag, budget: budget)
        arguments << "-#{flag}"
      end
      {"-J" => join, "-e" => escapes, "-C" => escape_bytes, "-N" => preserve_trailing,
        "-a" => alternate, "-P" => pending}.each { |flag, enabled| arguments << flag if enabled }
      server.__send__(:execute_typed, arguments, **budget.options)
    end

    def send_text(text, timeout: 5.0, cancel: nil)
      raise ArgumentError, "text must be a String" unless text.is_a?(String)

      server.__send__(:execute_typed, ["send-keys", "-l", "-t", target, "--", text], timeout: timeout, cancel: cancel)
    end

    def send_keys(*keys, timeout: 5.0, cancel: nil)
      raise ArgumentError, "provide at least one key name" if keys.empty?

      server.__send__(:execute_typed, ["send-keys", "-t", target, "--", *keys], timeout: timeout, cancel: cancel)
    end
  end

  class WindowLink < Entity
    def index
      ref.index
    end

    def window
      server.__send__(:build_entity, :window, id)
    end

    def session
      server.__send__(:build_entity, :session, ref.session_id)
    end

    def select(timeout: 5.0, cancel: nil)
      server.__send__(:execute_link, [ref], "select-window", ["-t", context], timeout: timeout, cancel: cancel)
    end

    def unlink(force: false, timeout: 5.0, cancel: nil)
      server.__send__(:execute_link, [ref], "unlink-window", [*(force ? ["-k"] : []), "-t", context], timeout: timeout, cancel: cancel)
    end

    def kill(timeout: 5.0, cancel: nil)
      server.__send__(:execute_link, [ref], "kill-window", ["-t", context], timeout: timeout, cancel: cancel)
    end

    def move(session:, index:, timeout: 5.0, cancel: nil)
      raise ArgumentError, "index must be a nonnegative Integer" unless index.is_a?(Integer) && index >= 0

      destination = server.__send__(:target, session, :session)
      server.__send__(:execute_link, [ref], "move-window", ["-d", "-s", context, "-t", "#{destination}:#{index}"], timeout: timeout, cancel: cancel)
    end

    def swap(other, timeout: 5.0, cancel: nil)
      server.__send__(:target, other, :window_link)
      server.__send__(:execute_link, [ref, other], "swap-window",
        ["-d", "-s", context, "-t", "#{other.session_id}:#{other.index}"], timeout: timeout, cancel: cancel)
    end

    def display(format, timeout: 5.0, cancel: nil)
      server.__send__(:execute_link, [ref], "display-message", ["-p", "-t", context, "--", format], timeout: timeout, cancel: cancel)
    end

    def options
      raise UnsupportedFeatureError.new("link-scoped options are not implemented; use an explicit window handle", phase: :admission)
    end

    def hooks
      raise UnsupportedFeatureError.new("link-scoped hooks are not implemented; use an explicit window handle", phase: :admission)
    end

    private

    def context
      "#{ref.session_id}:#{ref.index}"
    end
  end
end
