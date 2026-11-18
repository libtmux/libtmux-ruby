# frozen_string_literal: true

require "json"

module LibTmux
  # Immutable feature decisions observed through one bound daemon.
  # Obtain a report with {Server#capabilities}; it remains a historical
  # observation after that server changes or closes, never mutation authority.
  class Capabilities
    # A native command and the flags a feature depends on.
    Command = Data.define(:command, :flags) do
      def to_h = super.transform_keys(&:to_s)
      private_class_method :new, :[]
    end

    # A library feature, its requirement, and this daemon's support decision.
    Feature = Data.define(:id, :name, :summary, :since, :handling, :error,
      :apis, :commands, :except, :supported) do
      def supported? = supported

      def to_h
        super.transform_keys(&:to_s).merge("handling" => handling.to_s,
          "commands" => commands.map(&:to_h))
      end

      private_class_method :new, :[]
    end

    # A release-specific repair or refusal, including whether it applies here.
    Workaround = Data.define(:id, :name, :summary, :releases, :handling,
      :apis, :commands, :active) do
      def active? = active

      def to_h
        super.transform_keys(&:to_s).merge("handling" => handling.to_s,
          "commands" => commands.map(&:to_h))
      end

      private_class_method :new, :[]
    end

    attr_reader :binding_key, :pid, :start_time, :version, :features, :workarounds

    def initialize(binding_key:, pid:, start_time:, release:)
      @binding_key, @pid, @start_time = binding_key.dup.freeze, pid, start_time
      @version = release.text.dup.freeze
      @features = Internal::Capabilities::CAPABILITIES.map do |entry|
        Feature.__send__(:new, **entry.to_h.transform_keys(&:to_sym),
          error: entry.error, except: entry.except, handling: entry.handling,
          commands: commands(entry.commands), supported: entry.available?(release))
      end.freeze
      @workarounds = Internal::Capabilities::WORKAROUNDS.map do |entry|
        Workaround.__send__(:new, **entry.to_h.transform_keys(&:to_sym),
          handling: entry.handling, commands: commands(entry.commands), active: entry.applies?(release))
      end.freeze
      freeze
    end
    private_class_method :new

    # The feature named by the registry. An unknown id raises KeyError.
    def feature(id)
      features.find { |entry| entry.id == id } || raise(KeyError, "no capability #{id}")
    end

    def supports?(id) = feature(id).supported?

    # The workaround named by the registry. An unknown id raises KeyError.
    def workaround(id)
      workarounds.find { |entry| entry.id == id } || raise(KeyError, "no workaround #{id}")
    end

    # A fresh JSON-compatible projection; its containers do not own the report.
    def to_h
      {"server_identity" => {"generation" => binding_key, "pid" => pid,
        "start_time" => start_time, "tmux_version" => version},
       "features" => features.map(&:to_h), "workarounds" => workarounds.map(&:to_h)}
    end

    private

    def commands(entries)
      entries.map { |entry| Command.__send__(:new, command: entry.command, flags: entry.flags) }.freeze
    end
  end

  module Internal
    # What the connected tmux daemon can do, in one table. Each gate in the
    # library reads its release floor or affected releases from here, and
    # the root capabilities.json manifest for the docs site is generated
    # from the same records, so behavior and documentation cannot diverge.
    # Quirks that need no caller decision stay out of the table. It sits
    # beside TmuxVersion, which holds the supported minimum.
    module Capabilities
      SCHEMA = "libtmux-capabilities/1"
      PORT = "ruby"
      ERROR = "LibTmux::UnsupportedFeatureError"

      # A tmux command and the single-letter flags a record depends on.
      Command = Data.define(:command, :flags) do
        def initialize(command:, flags: [])
          super(command: command, flags: flags.freeze)
        end

        def to_h
          flags.empty? ? {"command" => command} : {"command" => command, "flags" => flags}
        end
      end

      # Something the library can do from tmux release +since+ on. Below it,
      # or on an +except+ release, +handling+ says what the library does.
      Capability = Data.define(:id, :name, :summary, :since, :handling, :error, :apis, :commands, :except) do
        def initialize(id:, name:, summary:, since:, handling:, apis:, commands:, error: nil, except: [])
          super(id: id, name: name, summary: summary, since: since, handling: handling, error: error,
            apis: apis.freeze, commands: commands.freeze, except: except.freeze)
        end

        # True when +release+ (an Internal::TmuxVersion::Release) offers it.
        def available?(release)
          release >= Internal::TmuxVersion.parse(since) && !except.include?(release.text)
        end

        def to_h
          {"id" => id, "name" => name, "summary" => summary, "since" => since,
           "handling" => handling.to_s}.tap do |hash|
            hash["error"] = error if error
            hash["except"] = except unless except.empty?
            hash["apis"] = apis
            hash["commands"] = commands.map(&:to_h)
          end
        end
      end

      # A defect on exact tmux releases that the library refuses or repairs.
      Workaround = Data.define(:id, :name, :summary, :releases, :handling, :apis, :commands) do
        def initialize(id:, name:, summary:, releases:, handling:, apis:, commands:)
          super(id: id, name: name, summary: summary, releases: releases.freeze, handling: handling,
            apis: apis.freeze, commands: commands.freeze)
        end

        # True when +release+ is one of the affected releases.
        def applies?(release)
          releases.include?(release.text)
        end

        def to_h
          {"id" => id, "name" => name, "summary" => summary, "releases" => releases,
           "handling" => handling.to_s, "apis" => apis, "commands" => commands.map(&:to_h)}
        end
      end

      # Public methods that send a tmux command line the caller wrote. The
      # command guard reads each line, so a capability it consults can refuse
      # a command through any of them, and only for the command it gates.
      RUN_CHANNELS = %w[
        LibTmux::Server#run LibTmux::Server#run_group LibTmux::Async::Server#run LibTmux::Async::Server#run_group
      ].freeze
      # The control-client channels, which reach a capability only on a tmux
      # that accepts control clients.
      CONTROL_CHANNELS = %w[LibTmux::ControlConnection#exchange LibTmux::Async::ControlConnection#exchange].freeze

      CAPABILITIES = [
        Capability.new(id: "control-mode", name: "Control mode", since: "3.7", handling: :refuse, error: ERROR,
          summary: "Attach a library-managed control client and stream events.",
          apis: ["LibTmux::Server#open_control", "LibTmux::Async::Server#open_control",
                 "LibTmux::ControlConnection.open", "LibTmux::ControlConnection.new"],
          commands: [Command.new(command: "attach-session")]),
        Capability.new(id: "buffer-delete-named", name: "Named buffer deletion", since: "3.4", handling: :refuse, error: ERROR,
          summary: "Delete one paste buffer by name without risking another buffer.",
          apis: ["LibTmux::Server#delete_buffer", "LibTmux::Async::Server#delete_buffer", *RUN_CHANNELS],
          commands: [Command.new(command: "delete-buffer", flags: ["-b"])]),
        Capability.new(id: "buffer-rename", name: "Buffer rename", since: "3.4", handling: :refuse, error: ERROR,
          summary: "Rename a paste buffer without risking another buffer.",
          apis: RUN_CHANNELS,
          commands: [Command.new(command: "set-buffer", flags: ["-b", "-n"])]),
        Capability.new(id: "layout-without-checksum", name: "Layouts without a checksum", since: "3.4",
          handling: :refuse, error: ERROR,
          summary: "Apply a layout string or a named layout that tmux validates before use.",
          apis: ["LibTmux::Window#select_layout", *RUN_CHANNELS],
          commands: [Command.new(command: "select-layout")]),
        Capability.new(id: "layout-mirrored-main", name: "Mirrored main layouts", since: "3.5",
          handling: :refuse, error: ERROR,
          summary: "Apply main-horizontal-mirrored and main-vertical-mirrored.",
          apis: ["LibTmux::Window#select_layout"],
          commands: [Command.new(command: "select-layout")]),
        Capability.new(id: "layout-json", name: "JSON layout strings", since: "3.8",
          handling: :refuse, error: ERROR,
          summary: "Apply a layout saved in the JSON form tmux reports.",
          apis: ["LibTmux::Window#select_layout", *RUN_CHANNELS, *CONTROL_CHANNELS],
          commands: [Command.new(command: "select-layout")]),
        Capability.new(id: "clipboard-query", name: "Clipboard query", since: "3.6a", handling: :refuse, error: ERROR,
          summary: "Ask an attached client's terminal for its clipboard with refresh-client -l.",
          apis: [*RUN_CHANNELS, *CONTROL_CHANNELS],
          commands: [Command.new(command: "refresh-client", flags: ["-l"])])
      ].freeze

      WORKAROUNDS = [
        Workaround.new(id: "break-pane-misnames-windows", name: "break-pane window naming", releases: ["3.7"],
          handling: :repair,
          summary: "break-pane gets the new window wrong on exactly tmux 3.7; Pane#break_out names it again, and raw break-pane is refused. A nested break-pane is not checked and stops an exact 3.7 daemon: name every one with -n, which avoids the crash while 3.7 still ignores the name, or upgrade to 3.7a.",
          apis: ["LibTmux::Pane#break_out", *RUN_CHANNELS, *CONTROL_CHANNELS],
          commands: [Command.new(command: "break-pane")]),
        Workaround.new(id: "split-window-percent-size", name: "split-window -p", releases: ["3.4"],
          handling: :refuse,
          summary: "split-window -p is broken on tmux 3.4; use -l N%.",
          apis: RUN_CHANNELS,
          commands: [Command.new(command: "split-window", flags: ["-p"])]),
        Workaround.new(id: "name-separators-rejected", name: "Colon and dot in names", releases: ["3.7"],
          handling: :refuse,
          summary: "tmux 3.7 rejects ':' and '.' in session and window names; the library refuses them before dispatch, typed or raw.",
          apis: ["LibTmux::Server#new_session", "LibTmux::Async::Server#new_session", "LibTmux::Session#new_window", "LibTmux::Session#rename",
                 "LibTmux::Window#rename", *RUN_CHANNELS],
          commands: [Command.new(command: "new-session", flags: ["-s"]), Command.new(command: "new-window", flags: ["-n"]),
                     Command.new(command: "rename-session"), Command.new(command: "rename-window")])
      ].freeze

      module_function

      # The record gating +id+; raises KeyError for an id the registry lacks.
      def capability(id) = CAPABILITIES.find { |entry| entry.id == id } || raise(KeyError, "no capability #{id}")

      def workaround(id) = WORKAROUNDS.find { |entry| entry.id == id } || raise(KeyError, "no workaround #{id}")

      # The manifest the docs site reads. The floor is the supported minimum.
      def manifest
        {"schema" => SCHEMA, "port" => PORT, "floor" => {"minimum" => Internal::TmuxVersion::MINIMUM},
         "capabilities" => CAPABILITIES.map(&:to_h), "workarounds" => WORKAROUNDS.map(&:to_h)}
      end

      # The exact text of capabilities.json: deterministic, with a final newline.
      def manifest_json = "#{JSON.pretty_generate(manifest)}\n"
    end
  end
end
