# frozen_string_literal: true

require "json"
require "libtmux/workspace"

module LibTmuxTest
  # tmuxp's example catalog, the structure each accepted file has to produce,
  # and the record of which tmuxp syntax the loader takes.
  #
  # The files under test/fixtures/tmuxp/expected were written by hand from what
  # tmuxp documents for each example, then checked against a real tmux in
  # test/integration/workspace_tmuxp_test.rb. No tmuxp ran to produce them, and
  # no test needs tmuxp or Python. Where this loader means something else, the
  # difference is listed below with its reason, and the test fails when the
  # loader stops differing.
  module TmuxpCatalog
    DIRECTORY = File.expand_path("../fixtures/tmuxp", __dir__)
    EXPECTED = File.join(DIRECTORY, "expected")
    SYNTAX = File.join(DIRECTORY, "syntax-support.json")
    WORKSPACE_DIR = "${WORKSPACE_DIR}"
    HOME = "${HOME}"

    # tmuxp's examples this loader reads.
    LOADED = %w[
      2-pane-vertical.yaml 3-pane.yaml 4-pane.yaml focus-window-and-panes.yaml main-pane-height.yaml
      session-environment.yaml shorthands.yaml start-directory.yaml window-index.yaml
    ].freeze

    # tmuxp's examples this loader refuses, with the message each one raises. A
    # change in the loader fails the case until the entry is updated or removed.
    REFUSED = {
      "2-pane-synchronized.yaml" => "invalid workspace configuration at $.windows[0]; expected supported data-only fields; move callbacks or hooks into explicit application code",
      "blank-panes.yaml" => "invalid workspace configuration at $.windows[0].panes[0]; expected configuration object",
      "env-variables.yaml" => "invalid workspace configuration at $.before_script; expected supported data-only fields; move callbacks or hooks into explicit application code",
      "main-pane-height-percentage.yaml" => "invalid workspace configuration at $.windows[0].options.main-pane-height; expected integer index from zero through 2147483647",
      "minimal.yaml" => "invalid workspace configuration at $.windows[0].window_name; expected window name",
      "options.yaml" => "invalid workspace configuration at $; expected supported data-only fields; move callbacks or hooks into explicit application code",
      "pane-shell.yaml" => "invalid workspace configuration at $.windows[0]; expected supported data-only fields; move callbacks or hooks into explicit application code",
      "plugin-system.yaml" => "invalid workspace configuration at $.plugins; expected supported data-only fields; move callbacks or hooks into explicit application code",
      "skip-send-pane-level.yaml" => "invalid workspace configuration at $.windows[0].window_name; expected window name",
      "skip-send.yaml" => "invalid workspace configuration at $.windows[0].window_name; expected window name",
      "sleep-pane-level.yaml" => "invalid workspace configuration at $.windows[0].window_name; expected window name",
      "sleep-virtualenv.yaml" => "invalid workspace configuration at $.shell_command_before; expected UTF-8 text",
      "sleep.yaml" => "invalid workspace configuration at $.windows[0].window_name; expected window name",
      "suppress-history.yaml" => "invalid workspace configuration at $; expected supported data-only fields; move callbacks or hooks into explicit application code"
    }.freeze

    # Where the loader means something other than tmuxp, and why. The reason
    # names the loader's rule; the test fails when the loader follows tmuxp.
    #
    # undeclared_directory: tmuxp leaves a start_directory nobody declared to
    #   tmux, which uses the directory tmuxp was started in. The loader starts
    #   every pane in the workspace file's directory, so the same file means the
    #   same panes wherever it is loaded from.
    # unexpanded_home: tmuxp expands a leading ~ to the home directory. The loader
    #   reads no ambient environment, so ~ is an ordinary relative name, a
    #   directory called ~ under the workspace file's directory; write an absolute
    #   path, or ${HOME} with expand_environment. Applying such a file stops at
    #   preflight, because that directory does not exist.
    # relative_to_workspace: tmuxp joins a relative window or pane start_directory
    #   to its parent's. The loader resolves every relative value against the
    #   workspace file's directory, so a value means the same wherever it is written.
    DIFFERENCES = {
      "start-directory.yaml" => [
        {rule: :relative_to_workspace, path: ["windows", 1], from: "/var/log", to: "#{WORKSPACE_DIR}/log"}
      ]
    }.freeze

    # Files whose build the loader's preflight stops, because a directory the
    # file names (see unexpanded_home) does not exist.
    UNBUILDABLE = %w[main-pane-height.yaml start-directory.yaml].freeze

    module_function

    def children
      Dir.children(DIRECTORY).grep(/\.yaml\z/).sort
    end

    def path(name)
      File.join(DIRECTORY, name)
    end

    def workspace(name)
      LibTmux::Workspace.load(path(name))
    end

    def expected(name)
      JSON.parse(File.read(File.join(EXPECTED, name.sub(/\.yaml\z/, ".json"))))
    end

    def syntax
      JSON.parse(File.read(SYNTAX))
    end

    # The loaded model in the shape of the expected files. A directory under
    # the workspace file's directory shows as ${WORKSPACE_DIR}.
    def structure(workspace, name)
      base = File.dirname(path(name))
      model = workspace.to_h
      directory = lambda do |value|
        if value == base then WORKSPACE_DIR
        elsif value.start_with?("#{base}/") then "#{WORKSPACE_DIR}#{value.delete_prefix(base)}"
        else value
        end
      end
      {"source" => nil,
       "session" => {"name" => model.fetch("session_name"), "start_directory" => directory.call(model.fetch("start_directory")),
                     "environment" => model.fetch("environment"), "options" => model.fetch("options")},
       "windows" => model.fetch("windows").map do |window|
         {"name" => window.fetch("window_name"), "index" => window.fetch("window_index"), "layout" => window["layout"],
          "focus" => window.fetch("focus"), "start_directory" => directory.call(window.fetch("start_directory")),
          "options" => window.fetch("options"),
          "panes" => window.fetch("panes").map do |pane|
            {"focus" => pane.fetch("focus"), "start_directory" => directory.call(pane.fetch("start_directory")),
             "environment" => pane.fetch("environment"),
             "commands" => pane.fetch("shell_command_before") + pane.fetch("shell_command")}
          end}
       end}
    end

    # The expected structure with the loader's differences applied.
    def port_expected(name)
      tree = expected(name).merge("source" => nil)
      each_directory(tree) do |holder|
        holder["start_directory"] = WORKSPACE_DIR if holder["start_directory"].nil?
        holder["start_directory"] = "#{WORKSPACE_DIR}/~#{holder['start_directory'].delete_prefix(HOME)}" if holder["start_directory"].start_with?(HOME)
      end
      DIFFERENCES.fetch(name, []).each do |difference|
        window = tree.dig(*difference.fetch(:path))
        each_directory({"windows" => [window]}) do |holder|
          holder["start_directory"] = difference.fetch(:to) if holder["start_directory"] == difference.fetch(:from)
        end
      end
      tree
    end

    # Yields the session, each window and each pane, which carry start_directory.
    def each_directory(tree, &block)
      block.call(tree["session"]) if tree["session"]
      tree.fetch("windows").each do |window|
        block.call(window)
        window.fetch("panes").each(&block)
      end
    end
  end
end
