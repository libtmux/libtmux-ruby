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

  # A session on one server, reached through a handle that wraps an {EntityRef}.
  # A handle never caches state: each method runs one tmux command, and
  # {Entity#snapshot} reads the session back as a record. Methods take `timeout:`
  # and `cancel:`, and raise {CommandError} when tmux rejects the command. A
  # listing that fails raises, so an empty array means tmux answered with nothing
  # to list.
  #
  # # What is on here
  #
  # The methods fall into the groups below.
  #
  # **Finding the session.** The server wraps a ref in a handle without running
  # a command, and a ref from another server raises {TargetNotFoundError}. A
  # handle reads back as a snapshot record through its ref.
  #
  # - Handles: {Server#session}, {Server#list_sessions}
  # - Read back as a record: {Entity#snapshot}
  #
  # **Looking inside a session.** Listing answers a frozen array of handles. The
  # pane listing covers every window of the session, and the link listing
  # answers each {WindowLink}, the session's own index for a window.
  #
  # - Windows: {#list_windows}
  # - Panes: {#list_panes}
  # - Window links: {#list_window_links}
  #
  # **Creating a window.** A new window starts detached unless `focus: true`, and
  # runs `command:`, an argv array rather than a shell string. It answers the
  # {Window}, or with `receipt: true` a {CreationReceipt}. `index:` places it at
  # that index.
  #
  # - Create a window: {#new_window}
  #
  # **Changing things.** Rename takes a nonempty name without NUL, and tmux 3.7
  # refuses `:` and `.` in it. Linking puts an existing window into this session
  # at an index. Kill stops the session; with both `expected_windows:` and
  # `expected_panes:` it refuses unless the session holds only those windows and
  # panes, and raises {TargetNotFoundError} otherwise.
  #
  # - Rename: {#rename}
  # - Link a window: {#link_window}
  # - Kill: {#kill}
  #
  # **Options, hooks and environment.** Ask for {Options} or {Hooks} scoped to the
  # session. Read, set, and unset one variable in the session's environment.
  #
  # - Options: {Entity#options}
  # - Hooks: {Entity#hooks}
  # - Read a variable: {#environment}
  # - Set a variable: {#set_environment}
  # - Unset a variable: {#unset_environment}
  #
  # **Expanding a format.** Display expands a tmux format against the session; the
  # argument is a format, not literal text.
  #
  # - Expand a format: {Entity#display}
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

  # A physical window on one server, reached through a handle that wraps an
  # {EntityRef}. Its index and whether it is current belong to a {WindowLink},
  # so one window can sit in several sessions. Methods take `timeout:` and
  # `cancel:`, and raise {CommandError} when tmux rejects the command.
  #
  # # What is on here
  #
  # The methods fall into the groups below.
  #
  # **Finding the window.** The server wraps a ref in a handle without running a
  # command, and a ref from another server raises {TargetNotFoundError}. A
  # session lists its windows, and a link answers the window it points at.
  #
  # - Handles: {Server#window}, {Server#list_windows}
  # - From a session: {Session#list_windows}
  # - From a link: {WindowLink#window}
  # - Read back as a record: {Entity#snapshot}
  #
  # **Looking inside a window.** Listing answers a frozen array of {Pane}
  # handles.
  #
  # - Panes: {#list_panes}
  #
  # **Splitting and arranging.** Splitting needs `direction:`, `:horizontal` or
  # `:vertical`, and `command:`, an argv array. `size:` is a count of cells or a
  # percentage string such as `"30%"`, and the new pane is detached unless
  # `focus: true`. It answers the new {Pane}. A layout is a native name, an
  # unambiguous prefix of one, or a saved layout. JSON layouts raise
  # {UnsupportedFeatureError} on a tmux without them. Resizing takes `width:`
  # or `height:`, and raises `ArgumentError` when given neither.
  #
  # - Split: {#split}
  # - Choose a layout: {#select_layout}
  # - Resize: {#resize}
  #
  # **Changing things.** Rename takes a nonempty name without NUL, and tmux 3.7
  # refuses `:` and `.` in it. Respawn runs `command:` again in the window, and
  # with `kill: true` replaces a running command. Kill removes the window from
  # the server.
  #
  # - Rename: {#rename}
  # - Respawn: {#respawn}
  # - Kill: {Entity#kill}
  #
  # **Options, hooks and formats.** Ask for {Options} or {Hooks} scoped to the
  # window. Display expands a tmux format against the window; the argument is a
  # format, not literal text.
  #
  # - Options: {Entity#options}
  # - Hooks: {Entity#hooks}
  # - Expand a format: {Entity#display}
  class Window < Entity
    LAYOUTS = %w[even-horizontal even-vertical main-horizontal main-vertical tiled].freeze
    MIRRORED_LAYOUTS = %w[main-horizontal-mirrored main-vertical-mirrored].freeze
    private_constant :LAYOUTS, :MIRRORED_LAYOUTS

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
      budget = server.__send__(:operation_budget, timeout, cancel)
      # Older tmux can access an invalid pointer for a malformed layout header.
      # tmux 3.8 and later report and accept saved layouts as JSON.
      saved = /\A[0-9a-fA-F]{4},/.match?(value)
      if !saved && value.start_with?("{")
        json = Internal::Capabilities.capability("layout-json")
        release = server.__send__(:tmux_release)
        unless json.available?(release)
          raise UnsupportedFeatureError.new("JSON layouts require tmux #{json.since} or newer " \
            "(connected version #{release.text})", phase: :admission, delivery: :not_sent)
        end
        saved = true
      end
      unless LAYOUTS.include?(value) || saved
        choices = (LAYOUTS + MIRRORED_LAYOUTS).select { |name| name.start_with?(value) }
        raise ArgumentError, "layout must be a native name or a saved layout" if value.empty? || choices.empty?

        if choices.any? { |name| MIRRORED_LAYOUTS.include?(name) }
          release = server.__send__(:tmux_release)
          mirrored = Internal::Capabilities.capability("layout-mirrored-main")
          unless mirrored.available?(release)
            choices &= LAYOUTS
            if choices.empty?
              raise UnsupportedFeatureError.new("mirrored layouts require tmux #{mirrored.since}+", phase: :admission)
            end
          end
        end
        choices = [value] if choices.include?(value)
        raise ArgumentError, "layout name is ambiguous" unless choices.length == 1

        value = choices.first
      end
      server.__send__(:execute_typed, ["select-layout", "-t", target, "--", value], **budget.options)
    end
  end

  # A physical pane on one server, reached through a handle that wraps an
  # {EntityRef}. Methods take `timeout:` and `cancel:`, and raise
  # {CommandError} when tmux rejects the command.
  #
  # # What is on here
  #
  # The methods fall into the groups below.
  #
  # **Finding the pane.** The server wraps a ref in a handle without running a
  # command, and a ref from another server raises {TargetNotFoundError}. A
  # session or a window lists its panes.
  #
  # - Handles: {Server#pane}, {Server#list_panes}
  # - From a session or window: {Session#list_panes}, {Window#list_panes}
  # - Read back as a record: {Entity#snapshot}
  #
  # **Sending input.** Text goes to the pane literally, so key names in it are
  # typed as characters. Keys are tmux key names such as `Enter` and `C-c`, and at
  # least one is required. Whether a program consumed the input is not known
  # when the command returns.
  #
  # - Literal text: {#send_text}
  # - Named keys: {#send_keys}
  #
  # **Reading output.** Capture answers the {CommandResult}, whose stdout holds
  # the screen. `start:` and `finish:` are integers or `"-"` for the edge of the
  # history. The alternate screen, the mode screen and the pending input are
  # mutually exclusive. Trimming trailing spaces and capturing the mode screen
  # raise {UnsupportedFeatureError} on a tmux that does not advertise the flag.
  #
  # - Capture: {#capture}
  #
  # **Splitting and arranging.** Splitting needs `direction:`, `:horizontal` or
  # `:vertical`, and `command:`, an argv array. It answers the new {Pane}, which
  # stays detached unless `focus: true`. Breaking out moves the pane into a new
  # window in the session you name and answers that {Window}.
  #
  # - Split: {#split}
  # - Resize: {#resize}
  # - Focus: {#select}
  # - Swap places: {#swap}
  # - Join or move: {#join}, {#move}
  # - Break out: {#break_out}
  #
  # **Copy mode, buffers and pipes.** Enter copy mode and send it a command, paste
  # a named buffer, or pipe the pane's output to a shell command. The shell
  # command and its format expansion are explicitly requested.
  #
  # - Copy mode: {#copy_mode}, {#copy_command}
  # - Paste a buffer: {#paste}
  # - Pipe output: {#pipe}
  #
  # **Changing things.** Respawn runs `command:` again in the pane, and with
  # `kill: true` replaces a running command. Kill removes the pane.
  #
  # - Respawn: {#respawn}
  # - Kill: {Entity#kill}
  #
  # **Options, hooks and formats.** Ask for {Options} or {Hooks} scoped to the
  # pane. Display expands a tmux format against the pane; the argument is a
  # format, not literal text.
  #
  # - Options: {Entity#options}
  # - Hooks: {Entity#hooks}
  # - Expand a format: {Entity#display}
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
