# frozen_string_literal: true

require_relative "options"

module LibTmux
  class Server
    def options(scope: :server)
      Options.__send__(:new, self, scope: scope)
    end

    def hooks(scope: :session)
      raise ArgumentError, "hooks use session or window scope" unless [:session, :window].include?(scope)

      Hooks.__send__(:new, self, scope: scope)
    end

    # Formats are intentionally executable tmux formats, not literal text.
    def display(format, target: nil, timeout: 5.0, cancel: nil)
      return window_link(target).display(format, timeout: timeout, cancel: cancel) if target.is_a?(EntityRef) && target.kind == :window_link

      args = ["display-message", "-p"]
      if target
        id = self.target(target, target.kind)
        args.concat(["-t", id])
        raise ArgumentError, "format must be a String" unless format.is_a?(String)

        # display-message accepts a missing -t target; bind its returned context
        # in this same command instead of accepting an empty fallback format.
        format = id_format(target.kind) + format
      end
      result = execute_typed([*args, "--", format], timeout: timeout, cancel: cancel)
      return result unless target

      prefix = "#{id.bytesize}:#{id}"
      unless result.stdout.start_with?(prefix)
        raise TargetNotFoundError.new("display target no longer exists", phase: :command, delivery: :observed)
      end
      CommandResult.new(stdout: result.stdout.byteslice(prefix.bytesize..), stderr: result.stderr,
        status: result.status, elapsed_seconds: result.elapsed_seconds, pid: result.pid, argv: result.argv)
    end

    def source_file(path, timeout: 5.0, cancel: nil)
      execute_typed(["source-file", "--", path], timeout: timeout, cancel: cancel)
    end

    # Retiring the client cannot remove a dispatched waiter from tmux's queue.
    def wait_for(channel, action: :wait, timeout: 5.0, cancel: nil)
      flag = {wait: nil, signal: "-S", lock: "-L", unlock: "-U"}.fetch(action) do
        raise ArgumentError, "action must be :wait, :signal, :lock or :unlock"
      end
      execute_typed(["wait-for", *[flag].compact, "--", channel], timeout: timeout, cancel: cancel)
    end

    def write_buffer(name:, data:, timeout: 5.0, cancel: nil)
      execute_typed(["load-buffer", "-b", name, "--", "-"], input: data, timeout: timeout, cancel: cancel)
    end

    def read_buffer(name, timeout: 5.0, cancel: nil)
      execute_typed(["save-buffer", "-b", name, "--", "-"], timeout: timeout, cancel: cancel)
    end

    def delete_buffer(name, timeout: 5.0, cancel: nil)
      execute_typed(["delete-buffer", "-b", name], timeout: timeout, cancel: cancel)
    end

    def list_buffers(timeout: 5.0, cancel: nil)
      result = execute_typed(["list-buffers", "-F", metadata_format(%w[buffer_name buffer_size])], timeout: timeout, cancel: cancel)
      Internal::Metadata.decode(result.stdout, fields: 2).map do |name, size|
        {name: name, size: decode_integer(size, "buffer size")}.freeze
      end.freeze
    end

    def list_window_links(timeout: 5.0, cancel: nil)
      acquire_links(["-a"], timeout: timeout, cancel: cancel)
    end

    def window_link(ref)
      resolve(ref, :window_link)
    end

    def set_environment(name, value, hidden: false, timeout: 5.0, cancel: nil)
      mutate_environment(["-g"], name, value, hidden: hidden, timeout: timeout, cancel: cancel)
    end

    def environment(name, hidden: false, timeout: 5.0, cancel: nil)
      read_environment(["-g"], name, hidden: hidden, timeout: timeout, cancel: cancel)
    end

    def unset_environment(name, timeout: 5.0, cancel: nil)
      execute_typed(["set-environment", "-g", "-u", "--", environment_name(name)], timeout: timeout, cancel: cancel)
    end

    def list_clients(timeout: 5.0, cancel: nil)
      fields = %w[client_name client_pid client_created client_tty session_id client_control_mode]
      result = execute_typed(["list-clients", "-F", metadata_format(fields)], timeout: timeout, cancel: cancel)
      Internal::Metadata.decode(result.stdout, fields: fields.length).map do |name, pid, created, tty, session_id, control|
        unless ["0", "1"].include?(control)
          raise FieldDecodeError.new("client control mode is malformed", phase: :decode, delivery: :observed)
        end
        {name: name, pid: decode_integer(pid, "client PID"), created: decode_integer(created, "client creation time"),
          tty: tty.empty? ? nil : tty, session_id: session_id.empty? ? nil : session_id, control: control == "1"}.freeze
      end.freeze
    end

    private

    # The format guard and nonwaiting mutation run within one tmux queue turn.
    # Resolve configured aliases first; concurrent alias reconfiguration is not
    # a supported coordination mechanism for these guarded operations.
    def execute_link(refs, command, arguments, timeout: 5.0, cancel: nil, budget: nil)
      budget ||= operation_budget(timeout, cancel)
      refs.each { |ref| target(ref, :window_link) }
      names = builtin_spellings("if-shell", "display-message", command, budget: budget)
      marker = "libtmux-missing-#{SecureRandom.hex(16)}"
      failure = tmux_command([names.fetch("display-message"), "-p", "--", marker])
      body = tmux_command([names.fetch(command), *arguments])
      refs.reverse_each do |ref|
        guard = "\#{&&:\#{==:\#{session_id},#{ref.session_id}},\#{&&:\#{==:\#{window_index},#{ref.index}},\#{==:\#{window_id},#{ref.id}}}}"
        body = tmux_command([names.fetch("if-shell"), "-F", "-t", "#{ref.session_id}:#{ref.index}", guard, body, failure])
      end
      # One command string is parsed by tmux; it never passes through a shell.
      result = execute_typed([names.fetch("if-shell"), "-F", "1", body], **budget.options)
      if result.stdout == "#{marker}\n"
        raise TargetNotFoundError.new("window link was removed or replaced", phase: :command, delivery: :observed)
      end
      result
    end

    def builtin_spellings(*commands, budget:)
      aliases = options(scope: :server).list(name: "command-alias", **budget.options).filter_map do |option|
        option.raw.split("=", 2).first if option.present?
      end
      result = execute_typed(["list-commands", "-F", metadata_format(%w[command_list_name command_list_alias])], **budget.options)
      catalog = Internal::Metadata.decode(result.stdout, fields: 2).to_h
      commands.uniq.to_h do |name|
        candidates = [name, catalog[name], *(1...name.length).map { |length| name[0, length] }.reverse].compact
        spelling = candidates.find do |candidate|
          next false if aliases.include?(candidate)

          exact_alias = catalog.find { |_key, value| value == candidate }&.first
          matching = exact_alias ? [exact_alias] : catalog.keys.select { |key| key.start_with?(candidate) }
          matching == [name] || candidate == name
        end
        raise UnsupportedFeatureError.new("all builtin spellings of #{name} are aliased", phase: :admission) unless spelling

        [name, spelling]
      end
    end

    def kill_session_with_windows(ref, expected, expected_panes, timeout:, cancel:)
      budget = operation_budget(timeout, cancel)
      id = target(ref, :session)
      unless expected.is_a?(Array) && expected.length <= 1024
        raise ArgumentError, "expected_windows must be an Array of at most 1024 window references"
      end
      unless expected_panes.is_a?(Array) && expected_panes.length <= 4096
        raise ArgumentError, "expected_panes must be an Array of at most 4096 pane references"
      end
      ids = expected.map { |window| target(window, :window) }.uniq
      pane_ids = expected_panes.map { |pane| target(pane, :pane) }.uniq
      names = builtin_spellings("if-shell", "display-message", "kill-session", budget: budget)
      allowed = ids.empty? ? "0" : "\#{m/r:^(#{ids.join('|')})$,\#{window_id}}"
      allowed_panes = pane_ids.empty? ? "0" : "\#{m/r:^(#{pane_ids.join('|')})$,\#{pane_id}}"
      guard = "\#{&&:\#{==:\#{session_id},#{id}},\#{==:\#{W:\#{?#{allowed},,w}\#{P:\#{?#{allowed_panes},,p}}},}}"
      marker = "libtmux-membership-#{SecureRandom.hex(16)}"
      failure = tmux_command([names.fetch("display-message"), "-p", "--", marker])
      body = tmux_command([names.fetch("kill-session"), "-t", id])
      result = execute_typed([names.fetch("if-shell"), "-F", "-t", id, guard, body, failure], **budget.options)
      if result.stdout == "#{marker}\n"
        raise TargetNotFoundError.new("session contains windows or panes outside the expected ownership sets", phase: :command, delivery: :observed)
      end
      result
    end

    def tmux_command(arguments)
      validate_argv(arguments)
      arguments.map { |argument| "'#{argument.gsub("'") { %q('\\'') }}'" }.join(" ")
    end

    def metadata_format(fields)
      fields.map { |field| "\#{n:#{field}}:\#{#{field}}" }.join
    end

    def decode_integer(value, label)
      unless value.match?(/\A\d+\z/)
        raise FieldDecodeError.new("#{label} is malformed", phase: :decode, delivery: :observed)
      end
      Integer(value, 10)
    end

    def require_command_flag(command, flag, budget:)
      result = execute_typed(["list-commands", "-F", metadata_format(%w[command_list_name command_list_usage]), command], **budget.options)
      commands = Internal::Metadata.decode(result.stdout, fields: 2).to_h
      usage = commands.fetch(command) do
        raise UnsupportedFeatureError.new("tmux does not advertise #{command}", phase: :admission)
      end
      unless usage.scan(/\[-([A-Za-z]+)(?:\]|\s)/).flatten.any? { |flags| flags.include?(flag) }
        raise UnsupportedFeatureError.new("tmux does not advertise #{command} -#{flag}", phase: :admission)
      end
    end

    def acquire_links(flags, timeout: 5.0, cancel: nil)
      result = execute_typed(["list-windows", *flags, "-F", metadata_format(%w[session_id window_index window_id])], timeout: timeout, cancel: cancel)
      Internal::Metadata.decode(result.stdout, fields: 3).map do |session_id, index, id|
        ref = EntityRef.__send__(:new, binding_key: @pin.key, kind: :window_link, id: id,
          session_id: session_id, index: decode_integer(index, "window index"))
        WindowLink.__send__(:new, self, ref)
      end.sort_by { |link| [link.ref.session_id[1..].to_i, link.index] }.freeze
    end

    def environment_name(name)
      unless name.is_a?(String) && name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        raise ArgumentError, "environment name must be a portable variable name"
      end
      name
    end

    def mutate_environment(flags, name, value, hidden:, timeout: 5.0, cancel: nil)
      execute_typed(["set-environment", *flags, *(hidden ? ["-h"] : []), "--", environment_name(name), value], timeout: timeout, cancel: cancel)
    end

    def read_environment(flags, name, hidden:, timeout: 5.0, cancel: nil)
      name = environment_name(name)
      result = execute_typed(["show-environment", *flags, *(hidden ? ["-h"] : []), "--", name], timeout: timeout, cancel: cancel)
      return nil if result.stdout == "-#{name}\n"
      unless result.stdout.start_with?("#{name}=") && result.stdout.end_with?("\n")
        raise ProtocolError.new("tmux returned an unexpected environment record", phase: :decode, delivery: :observed)
      end
      result.stdout.byteslice(name.bytesize + 1, result.stdout.bytesize - name.bytesize - 2).freeze
    end
  end

  class Entity
    def options
      Options.__send__(:new, server, ref: ref)
    end

    def hooks
      Hooks.__send__(:new, server, ref: ref)
    end

    def display(format, timeout: 5.0, cancel: nil)
      server.display(format, target: ref, timeout: timeout, cancel: cancel)
    end
  end

  class Session
    # Both allowlists are required for guarded deletion of a changing topology.
    def kill(expected_windows: nil, expected_panes: nil, timeout: 5.0, cancel: nil)
      return super(timeout: timeout, cancel: cancel) if expected_windows.nil? && expected_panes.nil?

      server.__send__(:kill_session_with_windows, ref, expected_windows, expected_panes, timeout: timeout, cancel: cancel)
    end

    def rename(name, timeout: 5.0, cancel: nil)
      server.__send__(:execute_typed, ["rename-session", "-t", target, "--", server.__send__(:literal_name, name)], timeout: timeout, cancel: cancel)
    end

    def list_window_links(timeout: 5.0, cancel: nil)
      server.__send__(:acquire_links, ["-t", target], timeout: timeout, cancel: cancel)
    end

    def link_window(window, index:, timeout: 5.0, cancel: nil)
      raise ArgumentError, "index must be a nonnegative Integer" unless index.is_a?(Integer) && index >= 0

      source = server.__send__(:target, window, :window)
      server.__send__(:execute_typed, ["link-window", "-d", "-s", source, "-t", "#{target}:#{index}"], timeout: timeout, cancel: cancel)
    end

    def set_environment(name, value, hidden: false, timeout: 5.0, cancel: nil)
      server.__send__(:mutate_environment, ["-t", target], name, value, hidden: hidden, timeout: timeout, cancel: cancel)
    end

    def environment(name, hidden: false, timeout: 5.0, cancel: nil)
      server.__send__(:read_environment, ["-t", target], name, hidden: hidden, timeout: timeout, cancel: cancel)
    end

    def unset_environment(name, timeout: 5.0, cancel: nil)
      server.__send__(:execute_typed, ["set-environment", "-t", target, "-u", "--", server.__send__(:environment_name, name)], timeout: timeout, cancel: cancel)
    end
  end

  class Window
    def rename(name, timeout: 5.0, cancel: nil)
      server.__send__(:execute_typed, ["rename-window", "-t", target, "--", server.__send__(:literal_name, name)], timeout: timeout, cancel: cancel)
    end

    def respawn(command:, kill: false, cwd: nil, environment: {}, timeout: 5.0, cancel: nil)
      budget = server.__send__(:operation_budget, timeout, cancel)
      args = ["respawn-window", "-t", target, *(kill ? ["-k"] : [])]
      args.concat(server.__send__(:creation_options, cwd: cwd, environment: environment))
      server.__send__(:execute_typed, [*args, "--", *server.__send__(:pane_command, command)], **budget.options)
    end

    def resize(width: nil, height: nil, timeout: 5.0, cancel: nil)
      dimensions = {"-x" => width, "-y" => height}.flat_map do |flag, value|
        next [] if value.nil?
        raise ArgumentError, "dimensions must be positive Integers" unless value.is_a?(Integer) && value.positive?

        [flag, value.to_s]
      end
      raise ArgumentError, "provide width or height" if dimensions.empty?

      server.__send__(:execute_typed, ["resize-window", "-t", target, *dimensions], timeout: timeout, cancel: cancel)
    end
  end

  class Pane
    def select(timeout: 5.0, cancel: nil)
      server.__send__(:execute_typed, ["select-pane", "-t", target], timeout: timeout, cancel: cancel)
    end

    def resize(width: nil, height: nil, direction: nil, amount: 1, zoom: false, timeout: 5.0, cancel: nil)
      args = ["resize-pane", "-t", target]
      {"-x" => width, "-y" => height}.each do |flag, value|
        next if value.nil?
        raise ArgumentError, "dimensions must be positive Integers" unless value.is_a?(Integer) && value.positive?

        args.concat([flag, value.to_s])
      end
      if direction
        flag = {left: "-L", right: "-R", up: "-U", down: "-D"}.fetch(direction) { raise ArgumentError, "invalid resize direction" }
        raise ArgumentError, "amount must be a positive Integer" unless amount.is_a?(Integer) && amount.positive?

        args.concat([flag, amount.to_s])
      end
      args << "-Z" if zoom
      server.__send__(:execute_typed, args, timeout: timeout, cancel: cancel)
    end

    def swap(other, timeout: 5.0, cancel: nil)
      server.__send__(:execute_typed, ["swap-pane", "-d", "-s", target, "-t", server.__send__(:target, other, :pane)], timeout: timeout, cancel: cancel)
    end

    def join(other, direction:, before: false, timeout: 5.0, cancel: nil)
      reposition("join-pane", other, direction: direction, before: before, timeout: timeout, cancel: cancel)
    end

    def move(other, direction:, before: false, timeout: 5.0, cancel: nil)
      reposition("move-pane", other, direction: direction, before: before, timeout: timeout, cancel: cancel)
    end

    def break_out(session:, name:, timeout: 5.0, cancel: nil)
      destination = server.__send__(:target, session, :session)
      server.__send__(:create_entity, :window, ["break-pane", "-d", "-P", "-F", server.__send__(:id_format, :window),
        "-s", target, "-t", "#{destination}:", "-n", server.__send__(:literal_name, name)], timeout: timeout, cancel: cancel)
    end

    def respawn(command:, kill: false, cwd: nil, environment: {}, timeout: 5.0, cancel: nil)
      budget = server.__send__(:operation_budget, timeout, cancel)
      args = ["respawn-pane", "-t", target, *(kill ? ["-k"] : [])]
      args.concat(server.__send__(:creation_options, cwd: cwd, environment: environment))
      server.__send__(:execute_typed, [*args, "--", *server.__send__(:pane_command, command)], **budget.options)
    end

    def paste(buffer:, delete: false, bracketed: false, separator: nil, timeout: 5.0, cancel: nil)
      args = ["paste-buffer", "-t", target, "-b", buffer]
      args << "-d" if delete
      args << "-p" if bracketed
      args.concat(["-s", separator]) if separator
      server.__send__(:execute_typed, args, timeout: timeout, cancel: cancel)
    end

    # The shell command and its format expansion are explicitly requested here.
    # only_if_closed follows tmux -o: an existing pipe is closed, not retained.
    def pipe(shell_command: nil, input: false, output: true, only_if_closed: false, timeout: 5.0, cancel: nil)
      if shell_command && !input && !output
        raise ArgumentError, "a pipe command requires input or output"
      end
      args = ["pipe-pane", "-t", target]
      args << "-I" if input
      args << "-O" if output
      args << "-o" if only_if_closed
      args.concat(["--", shell_command]) if shell_command
      server.__send__(:execute_typed, args, timeout: timeout, cancel: cancel)
    end

    def copy_mode(scroll_up: false, exit_on_bottom: false, mouse_drag: false, cancel_mode: false, page_down: false, source: nil, timeout: 5.0, cancel: nil)
      budget = server.__send__(:operation_budget, timeout, cancel)
      args = ["copy-mode", "-t", target]
      {"u" => scroll_up, "e" => exit_on_bottom, "M" => mouse_drag, "q" => cancel_mode, "d" => page_down}.each do |flag, enabled|
        next unless enabled

        server.__send__(:require_command_flag, "copy-mode", flag, budget: budget)
        args << "-#{flag}"
      end
      if source
        server.__send__(:require_command_flag, "copy-mode", "s", budget: budget)
        args.concat(["-s", server.__send__(:target, source, :pane)])
      end
      server.__send__(:execute_typed, args, **budget.options)
    end

    def copy_command(command, *arguments, timeout: 5.0, cancel: nil)
      server.__send__(:execute_typed, ["send-keys", "-X", "-t", target, "--", command, *arguments], timeout: timeout, cancel: cancel)
    end

    private

    def reposition(command, other, direction:, before:, timeout:, cancel:)
      flag = {horizontal: "-h", vertical: "-v"}.fetch(direction) { raise ArgumentError, "invalid split direction" }
      args = [command, "-d", flag, "-s", target, "-t", server.__send__(:target, other, :pane)]
      args << "-b" if before
      server.__send__(:execute_typed, args, timeout: timeout, cancel: cancel)
    end
  end
end
