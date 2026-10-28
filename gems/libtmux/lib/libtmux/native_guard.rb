# frozen_string_literal: true

require "libtmux/errors"
require "libtmux/capabilities"

module LibTmux
  module Internal
    # Refuses literal native commands that a connected tmux release mishandles.
    #
    # The guard reads the argv a caller submits: command separators, option
    # clusters and the abbreviations tmux resolves. Tmux command strings nested
    # in another command (if-shell and run-shell -C bodies, brace blocks) and
    # command-alias contents are not read, so a command this guard refuses must
    # not be nested there. The command table is a superset across releases, so
    # an abbreviation that is ambiguous on any supported release counts as
    # ambiguous.
    module NativeGuard
      COMMANDS = [
      "attach-session", "bind-key", "break-pane", "capture-pane", "choose-buffer",
      "choose-client", "choose-tree", "clear-history", "clear-prompt-history", "clock-mode",
      "command-prompt", "confirm-before", "copy-mode", "customize-mode", "delete-buffer",
      "detach-client", "display-menu", "display-message", "display-popup", "display-panes",
      "find-window", "has-session", "if-shell", "join-pane", "kill-pane", "kill-server",
      "kill-session", "kill-window", "last-pane", "last-window", "link-window", "list-buffers",
      "list-clients", "list-commands", "list-keys", "list-panes", "list-sessions",
      "list-windows", "load-buffer", "lock-client", "lock-server", "lock-session", "move-pane",
      "move-window", "new-pane", "new-session", "new-window", "next-layout", "next-window",
      "paste-buffer", "pipe-pane", "previous-layout", "previous-window", "refresh-client",
      "rename-session", "rename-window", "resize-pane", "resize-window", "respawn-pane",
      "respawn-window", "rotate-window", "run-shell", "save-buffer", "select-layout",
      "select-pane", "select-window", "send-keys", "send-prefix", "server-access",
      "set-buffer", "set-environment", "set-hook", "set-option", "set-window-option",
      "show-buffer", "show-environment", "show-hooks", "show-messages", "show-options",
      "show-prompt-history", "show-window-options", "source-file", "split-window",
      "start-server", "suspend-client", "swap-pane", "swap-window", "switch-client",
      "switch-mode", "unbind-key", "unlink-window", "wait-for"
      ].freeze
      ALIASES = {
        "attach" => "attach-session",
        "bind" => "bind-key",
        "breakp" => "break-pane",
        "capturep" => "capture-pane",
        "clearhist" => "clear-history",
        "clearphist" => "clear-prompt-history",
        "confirm" => "confirm-before",
        "deleteb" => "delete-buffer",
        "detach" => "detach-client",
        "display" => "display-message",
        "displayp" => "display-panes",
        "findw" => "find-window",
        "has" => "has-session",
        "if" => "if-shell",
        "joinp" => "join-pane",
        "killp" => "kill-pane",
        "killw" => "kill-window",
        "last" => "last-window",
        "lastp" => "last-pane",
        "linkw" => "link-window",
        "loadb" => "load-buffer",
        "lock" => "lock-server",
        "lockc" => "lock-client",
        "locks" => "lock-session",
        "ls" => "list-sessions",
        "lsb" => "list-buffers",
        "lsc" => "list-clients",
        "lscm" => "list-commands",
        "lsk" => "list-keys",
        "lsp" => "list-panes",
        "lsw" => "list-windows",
        "menu" => "display-menu",
        "movep" => "move-pane",
        "movew" => "move-window",
        "new" => "new-session",
        "newp" => "new-pane",
        "neww" => "new-window",
        "next" => "next-window",
        "nextl" => "next-layout",
        "pasteb" => "paste-buffer",
        "pipep" => "pipe-pane",
        "popup" => "display-popup",
        "prev" => "previous-window",
        "prevl" => "previous-layout",
        "refresh" => "refresh-client",
        "rename" => "rename-session",
        "renamew" => "rename-window",
        "resizep" => "resize-pane",
        "resizew" => "resize-window",
        "respawnp" => "respawn-pane",
        "respawnw" => "respawn-window",
        "rotatew" => "rotate-window",
        "run" => "run-shell",
        "saveb" => "save-buffer",
        "selectl" => "select-layout",
        "selectp" => "select-pane",
        "selectw" => "select-window",
        "send" => "send-keys",
        "set" => "set-option",
        "setb" => "set-buffer",
        "setenv" => "set-environment",
        "setw" => "set-window-option",
        "show" => "show-options",
        "showb" => "show-buffer",
        "showenv" => "show-environment",
        "showmsgs" => "show-messages",
        "showphist" => "show-prompt-history",
        "showw" => "show-window-options",
        "source" => "source-file",
        "splitw" => "split-window",
        "start" => "start-server",
        "suspendc" => "suspend-client",
        "swapp" => "swap-pane",
        "swapw" => "swap-window",
        "switchc" => "switch-client",
        "unbind" => "unbind-key",
        "unlinkw" => "unlink-window",
        "wait" => "wait-for"
      }.freeze
      OPTIONS = {
        "delete-buffer" => "b:",
        "set-buffer" => "ab:t:n:w",
        "break-pane" => "abdPF:n:s:t:",
        "split-window" => "bc:de:fF:hIl:p:Pt:vZ",
        "select-layout" => "Enopt:",
        "new-session" => "Ac:dDe:EF:f:n:Ps:t:x:Xy:",
        "new-window" => "abc:de:F:kn:PSt:",
        "rename-session" => "t:",
        "rename-window" => "t:",
        "refresh-client" => "A:B:cC:Df:F:lLRSt:U"
      }.freeze
      PRESETS = %w[even-horizontal even-vertical main-horizontal main-vertical tiled].freeze
      private_constant :COMMANDS, :ALIASES, :OPTIONS, :PRESETS
      module_function

      # +repaired_break+ marks a typed break-pane that renames its window after
      # the move, which exact tmux 3.7 requires.
      def check(argv, release, repaired_break: false)
        check_items(items(argv), release, repaired_break: repaired_break)
      end

      # Checks one raw command line, as a control connection sends it. A line
      # is a tmux command string, so quotes, backslashes and braces group
      # words the way tmux parses them before the same rules apply.
      def check_line(line, release)
        check_items(parse_line(line), release)
      end

      def check_items(items, release, repaired_break: false)
        items.each do |item|
          command = resolve(item.first)
          case command
          when "delete-buffer"
            gate = Internal::Capabilities.capability("buffer-delete-named")
            refuse("exact named-buffer deletion", gate.since, release) if !gate.available?(release) && flags(item, command).key?("b")
          when "set-buffer"
            given = flags(item, command)
            gate = Internal::Capabilities.capability("buffer-rename")
            refuse("exact named-buffer rename", gate.since, release) if !gate.available?(release) && given.key?("b") && given.key?("n")
          when "break-pane"
            if Internal::Capabilities.workaround("break-pane-misnames-windows").applies?(release) && !(repaired_break && flags(item, command).key?("n"))
              refuse_raw_break(release)
            end
          when "split-window"
            if Internal::Capabilities.workaround("split-window-percent-size").applies?(release) && flags(item, command).key?("p")
              raise UnsupportedFeatureError.new("split-window -p is broken on tmux #{release.text}; use -l with a percentage",
                phase: :admission, delivery: :not_sent)
            end
          when "select-layout"
            check_layout(item, command, release)
          when "new-session"
            given = flags(item, command)
            check_name(given["s"], release)
            check_name(given["n"], release)
          when "new-window"
            check_name(flags(item, command)["n"], release)
          when "rename-session", "rename-window"
            check_name(operands(item, command).first, release)
          when "refresh-client"
            # tmux 3.3a stops when it asks an attached xterm-256color or
            # tmux-256color terminal for its clipboard, and 3.4 through 3.6
            # stop when that client leaves before its terminal answers.
            gate = Internal::Capabilities.capability("clipboard-query")
            refuse("refresh-client -l", gate.since, release) if !gate.available?(release) && flags(item, command).key?("l")
          end
        end
        nil
      end

      # tmux joins arguments into commands: a bare ";" or a trailing ";" ends
      # one, and a trailing "\\;" is a literal semicolon.
      def items(argv)
        result = [[]]
        argv.each do |argument|
          if argument == ";"
            result << []
          elsif argument.end_with?(";") && !argument.end_with?("\\;")
            result.last << argument.delete_suffix(";") unless argument == ";"
            result << []
          else
            result.last << argument
          end
        end
        result.reject(&:empty?)
      end

      # Splits a command string into commands of words. A bare or trailing
      # unquoted ";" ends a command, a backslash makes the next character
      # literal, quotes group words, and a brace block stays one word.
      def parse_line(line)
        result = [[]]
        word = quote = nil
        depth = 0
        chars = line.each_char.to_a
        index = 0
        finish = lambda do
          result.last << word if word
          word = nil
        end
        while index < chars.length
          char = chars[index]
          if depth.positive?
            word << char
            depth += 1 if char == "{"
            depth -= 1 if char == "}"
          elsif quote == "'"
            char == "'" ? quote = nil : word << char
          elsif quote == '"'
            if char == '"'
              quote = nil
            elsif char == "\\" && index + 1 < chars.length
              index += 1
              word << chars[index]
            else
              word << char
            end
          else
            case char
            when /\s/ then finish.call
            when "'", '"'
              word ||= +""
              quote = char
            when "\\"
              word ||= +""
              index += 1
              word << chars[index] if index < chars.length
            when ";"
              finish.call
              result << []
            when "{"
              if word.nil?
                word = +"{"
                depth = 1
              else
                word << char
              end
            when "#"
              break if word.nil?

              word << char
            else
              (word ||= +"") << char
            end
          end
          index += 1
        end
        finish.call
        result.reject(&:empty?)
      end

      def resolve(name)
        return name if COMMANDS.include?(name)
        return ALIASES.fetch(name) if ALIASES.key?(name)

        matches = COMMANDS.select { |command| command.start_with?(name) }
        matches.length == 1 ? matches.first : nil
      end

      def flags(item, command)
        spec = OPTIONS.fetch(command)
        given = {}
        rest = item.drop(1)
        until rest.empty?
          token = rest.shift
          break if token == "--" || !token.start_with?("-") || token == "-"

          token[1..].each_char.with_index(1) do |flag, index|
            position = spec.index(flag)
            next unless position

            if spec[position + 1] == ":"
              given[flag] = token[(index + 1)..].empty? ? rest.shift : token[(index + 1)..]
              break
            end
            given[flag] = true
          end
        end
        given
      end

      def operands(item, command)
        spec = OPTIONS.fetch(command)
        rest = item.drop(1)
        until rest.empty?
          token = rest.first
          return rest.drop(1) if token == "--"
          return rest if !token.start_with?("-") || token == "-"

          rest.shift
          token[1..].each_char.with_index(1) do |flag, index|
            position = spec.index(flag)
            next unless position && spec[position + 1] == ":"

            rest.shift if token[(index + 1)..].empty?
            break
          end
        end
        rest
      end

      # tmux 3.3a faults on a header that is not four hex digits and a comma, so
      # only checksummed layouts and built-in names pass before 3.4. A JSON layout
      # needs tmux 3.8.
      def check_layout(item, command, release)
        given = flags(item, command)
        json = Internal::Capabilities.capability("layout-json")
        if !json.available?(release) && operands(item, command).first.to_s.start_with?("{") && given.slice("E", "n", "p").empty?
          raise UnsupportedFeatureError.new("JSON layouts require tmux #{json.since} or newer " \
            "(connected version #{release.text})", phase: :admission, delivery: :not_sent)
        end
        return if Internal::Capabilities.capability("layout-without-checksum").available?(release)

        return if given.key?("E") || given.key?("n") || given.key?("p")

        layout = operands(item, command).first
        return if layout.nil? || layout.match?(/\A[0-9a-fA-F]{4},[\s\S]+/)
        return if !given.key?("o") && PRESETS.count { |name| name.start_with?(layout) } == 1

        raise UnsupportedFeatureError.new("an invalid layout is refused before dispatch on tmux #{release.text}; " \
          "use a unique built-in layout name or a serialized layout", phase: :admission, delivery: :not_sent)
      end

      def check_name(name, release)
        return unless name.is_a?(String) && name.match?(/[:.]/)
        return unless Internal::Capabilities.workaround("name-separators-rejected").applies?(release)

        raise UnsupportedFeatureError.new("tmux 3.7 rejects ':' and '.' in session and window names",
          phase: :admission, delivery: :not_sent)
      end

      def refuse(what, floor, release)
        raise UnsupportedFeatureError.new("#{what} requires tmux #{floor} or newer (connected version #{release.text})",
          phase: :admission, delivery: :not_sent)
      end

      def refuse_raw_break(release)
        raise UnsupportedFeatureError.new("break-pane is unsafe on tmux #{release.text}; use Pane#break_out, " \
          "which names the window, or upgrade to 3.7a", phase: :admission, delivery: :not_sent)
      end
    end
  end
end
