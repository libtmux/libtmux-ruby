# frozen_string_literal: true

require "libtmux/owned"

module LibTmux
  # Evidence accepted through one retained socket route. The reserved server
  # option must not be changed or shadowed while an owner remains open.
  class OwnershipReceipt
    attr_reader :kind, :id, :pid, :started_at, :generation

    def initialize(kind:, id:, pid:, started_at:, generation:)
      @kind, @id, @pid, @started_at = kind, id&.dup&.freeze, pid, started_at
      @generation = generation.dup.freeze
      freeze
    end
    private_class_method :new
  end

  # Explicit responsibility for destroying a remote resource. The borrowed
  # client must remain open until close succeeds. Failed close remains retryable.
  class OwnedResource
    attr_reader :resource, :receipt, :cleanup_error

    def initialize(resource, receipt)
      @resource, @receipt = resource, receipt
      @mutex = Mutex.new
      @closed = false
      @destroyed = false
      @cleanup_error = nil
    end
    private_class_method :new

    def closed?
      @mutex.synchronize { @closed }
    end

    def close(timeout: 5.0)
      previous = Thread.current[:libtmux_lifecycle_cleanup]
      Thread.current[:libtmux_lifecycle_cleanup] = true
      Thread.handle_interrupt(Exception => :never) do
        @mutex.synchronize do
          return nil if @closed

          begin
            server = resource.is_a?(Server) ? resource : resource.server
            unless @destroyed
              server.__send__(:destroy_owned, receipt, timeout: timeout)
              @destroyed = true
            end
            server.close if receipt.kind == :server && server.owned?
            @closed = true
            @cleanup_error = nil
          rescue Exception => error
            @cleanup_error = error
            raise
          end
        end
      end
      nil
    ensure
      Thread.current[:libtmux_lifecycle_cleanup] = previous
    end

    # Ruby block exit, including raise/throw/break, releases this resource.
    # CleanupError preserves both failures and exposes this owner for retry.
    def use
      raise ArgumentError, "use requires a block" unless block_given?

      failure = nil
      Thread.handle_interrupt(Exception => :never) do
        begin
          Thread.handle_interrupt(Exception => :immediate) { yield resource }
        rescue Exception => error
          failure = error
          raise
        ensure
          begin
            close
          rescue Exception => cleanup
            raise CleanupError.new(body_error: failure, cleanup_error: cleanup, recovery: self) if failure

            raise
          end
        end
      end
    end
  end

  # A reused resource has no owner. Call resource.adopt to accept destruction.
  class Acquisition
    attr_reader :resource, :owner

    def initialize(resource:, owner: nil)
      @resource, @owner = resource, owner
      freeze
    end
    private_class_method :new

    def created?
      !owner.nil?
    end

    def use
      raise ArgumentError, "use requires a block" unless block_given?

      owner ? owner.use { |resource| yield resource } : yield(resource)
    end
  end

  class DiscoveredServer
    attr_reader :endpoint, :pid, :started_at

    def initialize(endpoint:, pid:, started_at:)
      @endpoint, @pid, @started_at = endpoint, pid, started_at
      freeze
    end
    private_class_method :new
  end

  class DiscoveryResult
    attr_reader :servers, :diagnostics, :entries, :probes

    def initialize(servers:, diagnostics:, entries:, probes:, truncated:)
      @servers = servers.freeze
      @diagnostics = diagnostics.map { |record| record.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze }.freeze
      @entries, @probes, @truncated = entries, probes, truncated
      freeze
    end
    private_class_method :new

    def truncated?
      @truncated
    end
  end

  class Entity
    # Killing a window removes every link and its panes, including linked copies.
    # A lookup alone never adopts an object. WindowLink is not an ownership target.
    def adopt(timeout: 5.0, cancel: nil, &block)
      server.__send__(:adopt_resource, self, timeout: timeout, cancel: cancel, &block)
    end
  end

  class Session
    def owned_window(name:, command:, **options, &block)
      server.__send__(:acquire_owned, :window, self, name: name, command: command, **options, &block)
    end

    # Exact window name in this session; two linked windows with that name fail.
    def find_or_create_window(name:, command:, timeout: 5.0, **options)
      server.__send__(:find_or_create_entity, :window, self, name: name, command: command, timeout: timeout, **options)
    end
  end

  class Window
    def owned_pane(direction:, command:, **options, &block)
      server.__send__(:acquire_owned, :pane, self, direction: direction, command: command, **options, &block)
    end

    # Identity is stored in the local pane option @libtmux_pane_identity.
    # Match within this window; identity is literal text, not a tmux format.
    def find_or_create_pane(identity:, direction:, command:, timeout: 5.0, **options)
      server.__send__(:find_or_create_entity, :pane, self, identity: identity, direction: direction,
        command: command, timeout: timeout, **options)
    end
  end

  class Pane
    def owned_pane(direction:, command:, **options, &block)
      server.__send__(:acquire_owned, :pane, self, direction: direction, command: command, **options, &block)
    end
  end

  class Server
    # Scans direct entries, without following symlinks, beneath explicit roots
    # or the captured current-user roots. Probes use retained routes and -N.
    # The entry bound counts roots too; errors and exhausted bounds are visible.
    def self.discover(roots: nil, env: ENV, executable: "tmux", max_entries: 256, max_probes: 64, timeout: 1.0, probe_timeout: 0.1)
      unless [max_entries, max_probes].all? { |value| value.is_a?(Integer) && value.positive? } &&
          [timeout, probe_timeout].all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? }
        raise ArgumentError, "discovery bounds must be positive and finite"
      end
      selected = Endpoint.new(env: env, executable: executable)
      captured = selected.environment
      roots ||= [File.dirname(selected.socket_path), File.join(captured.fetch("TMUX_TMPDIR", "/tmp").then { |value| value.empty? ? "/tmp" : value }, "tmux-#{Process.uid}"), "/tmp/tmux-#{Process.uid}"].uniq
      unless roots.is_a?(Array) && roots.all? { |root| root.is_a?(String) && root.start_with?("/") && !root.include?("\0") }
        raise ArgumentError, "roots must be an Array of absolute directory paths"
      end
      entries = probes = 0
      servers, diagnostics, seen = [], [], {}
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      truncated = false
      bounded = lambda do |path|
        reason = if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          :time_bound
        elsif entries >= max_entries
          :entry_bound
        end
        if reason
          truncated = true
          diagnostics << {path: path, reason: reason}
          true
        else
          entries += 1
          false
        end
      end
      catch(:bounded) do
        roots.uniq.each do |root|
          throw :bounded if bounded.call(root)
          begin
            stat = File.lstat(root)
            unless stat.directory? && !stat.symlink?
              diagnostics << {path: root, reason: :not_directory}
              next
            end
            Dir.open(root) do |directory|
              directory.each_child do |name|
                path = File.join(root, name)
                throw :bounded if bounded.call(path)
                begin
                  stat = File.lstat(path)
                  unless stat.socket?
                    diagnostics << {path: path, reason: stat.symlink? ? :symlink : :not_socket}
                    next
                  end
                  identity = [stat.dev, stat.ino]
                  if seen[identity]
                    diagnostics << {path: path, reason: :duplicate_socket}
                    next
                  end
                  seen[identity] = true
                  if probes >= max_probes
                    truncated = true
                    diagnostics << {path: path, reason: :probe_bound}
                    throw :bounded
                  end
                  probes += 1
                  endpoint = Endpoint.new(socket_path: path, executable: selected.executable, env: captured)
                  remaining = [probe_timeout, deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)].min
                  raise DeadlineExceeded.new("discovery time bound elapsed", phase: :admission) unless remaining.positive?
                  open(endpoint: endpoint) do |server|
                    output = server.display("\#{pid}|\#{start_time}", timeout: remaining).stdout
                    match = /\A([1-9][0-9]*)\|([0-9]+)\n/n.match(output)
                    raise ProtocolError.new("probe did not return a daemon identity", phase: :decode, delivery: :observed) unless match
                    servers << DiscoveredServer.__send__(:new, endpoint: endpoint, pid: Integer(match[1], 10), started_at: Integer(match[2], 10))
                  end
                rescue StandardError => error
                  diagnostics << {path: path, reason: :probe_failed, error: error.class.name}
                end
              end
            end
          rescue SystemCallError => error
            diagnostics << {path: root, reason: :root_failed, error: error.class.name}
          end
        end
      end
      DiscoveryResult.__send__(:new, servers: servers, diagnostics: diagnostics, entries: entries, probes: probes, truncated: truncated)
    end

    # Adopts this daemon; client close still only retires client transports.
    def adopt(timeout: 5.0, cancel: nil, &block)
      adopt_resource(self, timeout: timeout, cancel: cancel, &block)
    end

    def owned_session(name:, command:, **options, &block)
      acquire_owned(:session, nil, name: name, command: command, **options, &block)
    end

    # Calls through these APIs serialize within one Ruby process, across handles.
    # Other processes and raw tmux commands do not participate in this boundary.
    def find_or_create_session(name:, command:, timeout: 5.0, **options)
      find_or_create_entity(:session, nil, name: name, command: command, timeout: timeout, **options)
    end

    # Existing endpoints are borrowed. Atomic hard-link publication refuses an
    # occupied pathname; stale sockets and ordinary files are not removed.
    def self.find_or_create(endpoint: nil, timeout: 5.0, config: nil, **options)
      raise ArgumentError, "endpoint cannot be combined with endpoint options" if endpoint && !options.empty?
      endpoint ||= Endpoint.new(**options)

      Internal.const_get(:LifecycleGate, false).synchronize(timeout: timeout) do |remaining|
        Thread.handle_interrupt(Exception => :never) do
          server = owner = nil
          begin
            begin
              server = new(endpoint: endpoint)
              # Binding an inode does not prove that a stale socket is alive.
              server.display("\#{pid}", timeout: remaining.call)
              result = Acquisition.__send__(:new, resource: server)
            rescue TargetNotFoundError
              raise if File.exist?(endpoint.socket_path) || File.symlink?(endpoint.socket_path)

              server = start(endpoint: endpoint, config: config, timeout: remaining.call)
              owner = server.adopt(timeout: remaining.call)
              result = Acquisition.__send__(:new, resource: server, owner: owner)
            end
            Thread.handle_interrupt(Exception => :immediate) { nil }
            result
          rescue Exception => failure
            begin
              server&.close
            rescue Exception => cleanup
              raise CleanupError.new(body_error: failure, cleanup_error: cleanup, recovery: owner)
            end
            raise
          end
        end
      end
    end

    private

    OWNER_OPTION = "@libtmux_owner_generation"
    PANE_IDENTITY = "@libtmux_pane_identity"
    private_constant :OWNER_OPTION, :PANE_IDENTITY

    def lifecycle_format(kind)
      id = kind == :server ? "server" : "\#{#{kind}_id}"
      "\#{pid}|\#{start_time}|\#{#{OWNER_OPTION}}|#{id}"
    end

    def lifecycle_names(budget, *commands)
      builtin_spellings("if-shell", "display-message", "set-option", *commands, budget: budget)
    end

    def lifecycle_initialize(names)
      tmux_command([names.fetch("set-option"), "-soq", OWNER_OPTION, SecureRandom.hex(16)])
    end

    def lifecycle_valid_generation
      "\#{&&:\#{==:\#{n:#{OWNER_OPTION}},32},\#{m/r:^[0-9a-fA-F]+$,\#{#{OWNER_OPTION}}}}"
    end

    # An owned mutation defers Ruby asynchronous exceptions until its receipt
    # has been decoded. Deadline/transport failure still reports unknown outcome.
    def lifecycle_execute(program, names, budget)
      arguments = encode_arguments([names.fetch("if-shell"), "-F", "1", program])
      options = budget.options
      result = perform_request(cancel: nil, interruptible: false) do |view|
        @executor.run(@pin.command_prefix + arguments, input: "".b,
          env: @endpoint.environment, timeout: options.fetch(:timeout), cancel: view)
      end
      result
    end

    def lifecycle_receipt(text, kind)
      prefix = {server: "server", session: "\\$[0-9]+", window: "@[0-9]+", pane: "%[0-9]+"}.fetch(kind)
      match = /\A([1-9][0-9]*)\|([0-9]+)\|([0-9a-fA-F]{32})\|(#{prefix})\n/n.match(text)
      unless match
        raise OutcomeUnknown.new("owned #{kind} command returned no complete receipt; inspect the retained endpoint before recovery",
          phase: :decode, delivery: :possibly_sent)
      end
      receipt = OwnershipReceipt.__send__(:new, kind: kind, id: kind == :server ? nil : match[4],
        pid: Integer(match[1], 10), started_at: Integer(match[2], 10), generation: match[3])
      [receipt, match[0].bytesize]
    end

    def owner_from_output(result, kind)
      if result.stdout == "invalid-owner-generation\n"
        raise ProtocolError.new("reserved owner generation is empty or malformed", phase: :admission, delivery: :observed)
      end
      receipt, consumed = lifecycle_receipt(result.stdout, kind)
      resource = kind == :server ? self : build_entity(kind, receipt.id)
      owner = OwnedResource.__send__(:new, resource, receipt)
      if consumed != result.stdout.bytesize
        begin
          raise ProtocolError.new("owned command returned extra receipt data", phase: :decode, delivery: :observed)
        rescue Exception => failure
          rollback_owner(owner, failure)
        end
      end
      owner
    end

    def rollback_owner(owner, failure)
      begin
        owner.close
      rescue Exception => cleanup
        raise CleanupError.new(body_error: failure, cleanup_error: cleanup, recovery: owner)
      end
      raise failure
    end

    def adopt_resource(resource, timeout:, cancel:, &block)
      kind = resource.equal?(self) ? :server : resource.ref.kind
      raise ArgumentError, "adopt requires a server, session, window or pane" unless %i[server session window pane].include?(kind)
      id = kind == :server ? nil : target(resource.ref, kind)
      owner = nil
      Thread.handle_interrupt(Exception => :never) do
        begin
          budget = operation_budget(timeout, cancel)
          names = lifecycle_names(budget)
          show = [names.fetch("display-message"), "-p", *(["-t", id] if id), "--", lifecycle_format(kind)]
          guard = kind == :server ? lifecycle_valid_generation : "\#{&&:#{lifecycle_valid_generation},\#{==:\#{#{kind}_id},#{id}}}"
          command = tmux_command([names.fetch("if-shell"), "-F", *(["-t", id] if id), guard,
            tmux_command(show), tmux_command([names.fetch("display-message"), "-p", "invalid-owner-target"])])
          result = lifecycle_execute([lifecycle_initialize(names), command].join(" ; "), names, budget)
          raise CommandError.new(result: result, phase: :command) unless result.success?
          if result.stdout == "invalid-owner-target\n"
            raise TargetNotFoundError.new("adoption target or reserved generation is invalid", phase: :admission, delivery: :observed)
          end
          receipt, count = lifecycle_receipt(result.stdout, kind)
          raise ProtocolError.new("adoption returned extra receipt data", phase: :decode, delivery: :observed) unless count == result.stdout.bytesize

          owner = OwnedResource.__send__(:new, resource, receipt)
          raise Cancelled.new("adoption cancelled after ownership acceptance", phase: :handoff, delivery: :observed) if cancel&.cancelled?
          Thread.handle_interrupt(Exception => :immediate) { nil }
        rescue Exception => failure
          rollback_owner(owner, failure) if owner
          raise
        end
        block ? owner.use(&block) : owner
      end
    end

    def acquire_owned(kind, parent, timeout: 5.0, cancel: nil, **options, &block)
      owner = nil
      Thread.handle_interrupt(Exception => :never) do
        begin
          budget = operation_budget(timeout, cancel)
          command = {session: "new-session", window: "new-window", pane: "split-window"}.fetch(kind)
          names = lifecycle_names(budget, command)
          arguments = owned_arguments(kind, parent, options)
          body = tmux_command([names.fetch(command), *arguments])
          checked = tmux_command([names.fetch("if-shell"), "-F", lifecycle_valid_generation, body,
            tmux_command([names.fetch("display-message"), "-p", "invalid-owner-generation"])])
          result = lifecycle_execute([lifecycle_initialize(names), checked].join(" ; "), names, budget)
          if !result.success? && result.stdout.empty?
            raise CommandError.new(result: result, phase: :command)
          end
          owner = owner_from_output(result, kind)
          raise CommandError.new(result: result, phase: :command) unless result.success?
          raise Cancelled.new("owned acquisition cancelled after creation", phase: :handoff, delivery: :observed) if cancel&.cancelled?
          Thread.handle_interrupt(Exception => :immediate) { nil }
        rescue Exception => failure
          rollback_owner(owner, failure) if owner
          raise
        end
        block ? owner.use(&block) : owner
      end
    end

    def owned_arguments(kind, parent, options)
      options = options.dup
      command = pane_command(options.delete(:command))
      arguments = ["-d", "-P", "-F", lifecycle_format(kind)]
      if kind == :pane
        direction = {horizontal: "-h", vertical: "-v"}.fetch(options.delete(:direction)) { raise ArgumentError, "direction must be :horizontal or :vertical" }
        arguments << direction
        arguments.concat(["-t", target(parent.ref, parent.ref.kind)])
        size = options.delete(:size)
        if size
          unless (size.is_a?(Integer) && size.between?(1, (1 << 31) - 1)) ||
              (size.is_a?(String) && size.match?(/\A(?:[1-9][0-9]?|100)%\z/))
            raise ArgumentError, "size must be positive cells or a percentage from 1% to 100%"
          end
          arguments.concat(["-l", size.to_s])
        end
      else
        name = literal_name(options.delete(:name))
        arguments.concat([kind == :session ? "-s" : "-n", name])
        if kind == :session
          window_name = options.delete(:window_name)
          arguments.concat(["-n", literal_name(window_name)]) if window_name
          {width: "-x", height: "-y"}.each do |key, flag|
            value = options.delete(key)
            next unless value
            raise ArgumentError, "dimensions must be positive integers" unless value.is_a?(Integer) && value.positive?
            arguments.concat([flag, value.to_s])
          end
        else
          destination = target(parent.ref, :session)
          index = options.delete(:index)
          if index
            raise ArgumentError, "index must be a nonnegative 32-bit Integer" unless index.is_a?(Integer) && index.between?(0, (1 << 31) - 1)
            destination += ":#{index}"
          end
          arguments.concat(["-t", destination])
        end
      end
      focus = options.delete(:focus)
      raise ArgumentError, "focus must be boolean" unless [nil, true, false].include?(focus)
      arguments.delete("-d") if focus
      arguments.concat(creation_options(cwd: options.delete(:cwd), environment: options.delete(:environment) || {}))
      raise ArgumentError, "unknown owned creation options: #{options.keys.join(', ')}" unless options.empty?

      [*arguments, "--", *command]
    end

    def destroy_owned(receipt, timeout:)
      budget = operation_budget(timeout, nil)
      command = "kill-#{receipt.kind}"
      names = lifecycle_names(budget, command)
      identity = "\#{&&:\#{==:\#{pid},#{receipt.pid}},\#{&&:\#{==:\#{start_time},#{receipt.started_at}},\#{==:\#{#{OWNER_OPTION}},#{receipt.generation}}}}"
      marker = "owner-replaced-#{SecureRandom.hex(16)}"
      missing = "owner-absent-#{SecureRandom.hex(16)}"
      failure = tmux_command([names.fetch("display-message"), "-p", marker])
      kill = tmux_command([names.fetch(command), *(["-t", receipt.id] if receipt.id)])
      if receipt.id
        present = "\#{==:\#{#{receipt.kind}_id},#{receipt.id}}"
        kill = tmux_command([names.fetch("if-shell"), "-F", "-t", receipt.id, present, kill,
          tmux_command([names.fetch("display-message"), "-p", missing])])
      end
      program = tmux_command([names.fetch("if-shell"), "-F", identity, kill, failure])
      result = lifecycle_execute(program, names, budget)
      raise CommandError.new(result: result, phase: :command) unless result.success?
      if result.stdout == "#{marker}\n"
        raise TargetNotFoundError.new("owned daemon generation changed; refusing destruction", phase: :command, delivery: :observed)
      end
      unless result.stdout.empty? || result.stdout == "#{missing}\n"
        raise ProtocolError.new("owned destruction returned unexpected output", phase: :decode, delivery: :observed)
      end
      nil
    end

    def find_or_create_entity(kind, parent, timeout:, cancel: nil, **options)
      budget = operation_budget(timeout, cancel)
      Internal.const_get(:LifecycleGate, false).synchronize(timeout: timeout, cancel: cancel) do
        owner = nil
        Thread.handle_interrupt(Exception => :never) do
          begin
            name = options[kind == :pane ? :identity : :name]
            literal_name(name)
            if (kind == :session && name.match?(/[.:]/)) || (kind != :pane && name.match?(/[\\\x00-\x1f\x7f]/))
              raise ArgumentError, "exact names cannot contain characters rewritten by tmux: backslash and controls, or dot and colon in session names"
            end
            entities = case kind
            when :session then list_sessions(**budget.options)
            when :window then parent.list_windows(**budget.options)
            when :pane then parent.list_panes(**budget.options)
            end
            field = kind == :pane ? PANE_IDENTITY : "#{kind}_name"
            matches = entities.select { |entity| lifecycle_value(entity, field, **budget.options) == name.b }
            raise MultipleMatchesError.new("multiple #{kind}s match the exact #{kind == :pane ? 'pane identity' : 'name'}", phase: :admission) if matches.length > 1
            if matches.length == 1
              result = Acquisition.__send__(:new, resource: matches.first)
            else
              create_options = options.reject { |key, _| key == :identity }
              owner = acquire_owned(kind, parent, **create_options, **budget.options)
              if kind == :pane
                owner.resource.options.set(PANE_IDENTITY, name, **budget.options)
                actual = lifecycle_value(owner.resource, field, **budget.options)
                raise ProtocolError.new("created pane did not retain its identity", phase: :decode, delivery: :observed) unless actual == name.b
              end
              result = Acquisition.__send__(:new, resource: owner.resource, owner: owner)
            end
            raise Cancelled.new("find or create cancelled before handoff", phase: :handoff, delivery: :observed) if cancel&.cancelled?
            Thread.handle_interrupt(Exception => :immediate) { nil }
            result
          rescue Exception => failure
            rollback_owner(owner, failure) if owner
            raise
          end
        end
      end
    end

    def lifecycle_value(entity, field, timeout:, cancel: nil)
      if field == PANE_IDENTITY
        values = entity.options.list(inherited: false, timeout: timeout, cancel: cancel).select { |value| value.name == field }
        return "".b if values.empty?
        unless values.length == 1 && !values.first.array?
          raise ProtocolError.new("pane identity must be a scalar local option", phase: :decode, delivery: :observed)
        end
        return values.first.raw
      end
      output = display(metadata_format([field]), target: entity.ref, timeout: timeout, cancel: cancel).stdout
      rows = Internal::Metadata.decode(output, fields: 1, max_rows: 1, quoted: true)
      raise ProtocolError.new("lookup did not return one value", phase: :decode, delivery: :observed) unless rows.length == 1
      rows.first.first
    end
  end

  module Internal
    module LifecycleGate
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @busy = false
      class << self
        def synchronize(timeout:, cancel: nil)
          unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
            raise ArgumentError, "timeout must be positive and finite"
          end
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          remaining = -> do
            raise Cancelled.new("find or create cancelled before gate admission", phase: :admission, delivery: :not_sent) if cancel&.cancelled?
            seconds = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise DeadlineExceeded.new("find-or-create deadline elapsed", phase: :admission) unless seconds.positive?
            seconds
          end
          Thread.handle_interrupt(Exception => :never) do
            admitted = false
            begin
              @mutex.synchronize do
                while @busy
                  seconds = remaining.call
                  @condition.wait(@mutex, cancel ? [seconds, 0.05].min : seconds)
                end
                remaining.call
                @busy = admitted = true
              end
              yield remaining
            ensure
              if admitted
                @mutex.synchronize do
                  @busy = false
                  @condition.broadcast
                end
              end
            end
          end
        end
      end
    end
    private_constant :LifecycleGate
  end
end
