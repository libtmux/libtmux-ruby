# frozen_string_literal: true

require "json"

module LibTmux
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

      CAPABILITIES = [
        Capability.new(id: "control-mode", name: "Control mode", since: "3.7", handling: :refuse, error: ERROR,
          summary: "Attach a library-managed control client and stream events.",
          apis: ["LibTmux::Server#open_control", "LibTmux::ControlConnection.open"],
          commands: [Command.new(command: "attach-session")]),
        Capability.new(id: "buffer-delete-named", name: "Named buffer deletion", since: "3.4", handling: :refuse, error: ERROR,
          summary: "Delete one paste buffer by name without risking another buffer.",
          apis: ["LibTmux::Server#delete_buffer", "LibTmux::Server#run"],
          commands: [Command.new(command: "delete-buffer", flags: ["-b"])]),
        Capability.new(id: "buffer-rename", name: "Buffer rename", since: "3.4", handling: :refuse, error: ERROR,
          summary: "Rename a paste buffer without risking another buffer.",
          apis: ["LibTmux::Server#run"],
          commands: [Command.new(command: "set-buffer", flags: ["-b", "-n"])]),
        Capability.new(id: "layout-without-checksum", name: "Layouts without a checksum", since: "3.4",
          handling: :refuse, error: ERROR,
          summary: "Apply a layout string or a named layout that tmux validates before use.",
          apis: ["LibTmux::Window#select_layout", "LibTmux::Server#run"],
          commands: [Command.new(command: "select-layout")]),
        Capability.new(id: "layout-mirrored-main", name: "Mirrored main layouts", since: "3.5",
          handling: :refuse, error: ERROR,
          summary: "Apply main-horizontal-mirrored and main-vertical-mirrored.",
          apis: ["LibTmux::Window#select_layout"],
          commands: [Command.new(command: "select-layout")]),
        Capability.new(id: "layout-json", name: "JSON layout strings", since: "3.8-rc2",
          handling: :refuse, error: ERROR,
          summary: "Apply a layout saved in the JSON form tmux reports.",
          apis: ["LibTmux::Window#select_layout"],
          commands: [Command.new(command: "select-layout")]),
        Capability.new(id: "clipboard-query", name: "Clipboard query", since: "3.6a", handling: :refuse, error: ERROR,
          summary: "Ask an attached client's terminal for its clipboard with refresh-client -l.",
          apis: ["LibTmux::Server#run", "LibTmux::ControlConnection#exchange"],
          commands: [Command.new(command: "refresh-client", flags: ["-l"])])
      ].freeze

      WORKAROUNDS = [
        Workaround.new(id: "break-pane-misnames-windows", name: "break-pane window naming", releases: ["3.7"],
          handling: :repair,
          summary: "break-pane gets the new window wrong on exactly tmux 3.7; Pane#break_out names it again, and raw break-pane is refused.",
          apis: ["LibTmux::Pane#break_out", "LibTmux::Server#run", "LibTmux::ControlConnection#exchange"],
          commands: [Command.new(command: "break-pane")]),
        Workaround.new(id: "split-window-percent-size", name: "split-window -p", releases: ["3.4"],
          handling: :refuse,
          summary: "split-window -p is broken on tmux 3.4; use -l N%.",
          apis: ["LibTmux::Server#run"],
          commands: [Command.new(command: "split-window", flags: ["-p"])]),
        Workaround.new(id: "name-separators-rejected", name: "Colon and dot in names", releases: ["3.7"],
          handling: :refuse,
          summary: "tmux 3.7 rejects ':' and '.' in session and window names; the library refuses them before dispatch, typed or raw.",
          apis: ["LibTmux::Server#new_session", "LibTmux::Session#new_window", "LibTmux::Session#rename",
                 "LibTmux::Window#rename", "LibTmux::Server#run"],
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
