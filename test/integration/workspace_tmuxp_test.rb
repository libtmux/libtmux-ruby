# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmuxp_catalog"
require "libtmux/workspace"

# Builds each of tmuxp's example files the loader accepts on a private tmux and
# compares the session, window and pane tree with the structure written by hand
# in test/fixtures/tmuxp/expected, read once the build has returned: names,
# indexes, pane counts, focus, directories, and whether the named layout is the
# one in effect. Pane contents, command output and anything that needs a command
# to have run stay out; the commands are only dispatched.
class WorkspaceTmuxpBuildTest < Minitest::Test
  Catalog = LibTmuxTest::TmuxpCatalog

  def start(&block)
    LibTmux::Server.start(executable: ENV.fetch("LIBTMUX_TEST_TMUX", "tmux"), &block)
  end

  # The tree tmux holds for the one session, in the shape of expected().
  def built(server)
    session = server.list_sessions.fetch(0)
    current = session.snapshot.current_window.id
    windows = session.list_window_links.sort_by(&:index).map do |link|
      window = link.window
      snapshot = window.snapshot
      layout = snapshot.layout
      window.select_layout(layout_name(window)) if layout_name(window)
      {"name" => snapshot.name, "index" => link.index, "focus" => snapshot.id == current,
       "layout" => layout_name(window) && window.snapshot.layout == layout,
       "panes" => window.list_panes.map do |pane|
         {"focus" => pane.snapshot.active, "start_directory" => File.realpath(pane.display('#{pane_start_path}').text.chomp)}
       end}
    end
    {"session" => session.snapshot.name, "windows" => windows}
  end

  def layout_name(window)
    @layouts.fetch(window.id, nil)
  end

  # What the expected structure says tmux should hold, in window index order,
  # with directories made real.
  def wanted(name)
    base = File.realpath(File.dirname(Catalog.path(name)))
    real = ->(directory) { File.realpath(directory.sub(Catalog::WORKSPACE_DIR, base)) }
    tree = Catalog.port_expected(name)
    {"session" => tree.dig("session", "name"),
     "windows" => tree.fetch("windows").sort_by { |window| window.fetch("index") }.map do |window|
       {"name" => window.fetch("name"), "index" => window.fetch("index"), "focus" => window.fetch("focus"),
        "layout" => window["layout"] ? true : nil,
        "panes" => window.fetch("panes").map { |pane| {"focus" => pane.fetch("focus"), "start_directory" => real.call(pane.fetch("start_directory"))} }}
     end}
  end

  (Catalog::LOADED - Catalog::UNBUILDABLE).each do |name|
    define_method("test_#{name.delete_suffix('.yaml').tr('-', '_')}_builds_the_tree_tmuxp_documents") do
      start do |server|
        workspace = Catalog.workspace(name)
        assert workspace.plan(snapshot: server.snapshot).apply(server: server).success?
        @layouts = workspace.to_h.fetch("windows").each_with_index.to_h { |window, index| [server.list_windows.fetch(index).id, window["layout"]] }
        assert_equal wanted(name), built(server)
      end
    end
  end

  def test_files_that_name_a_home_directory_stop_at_preflight_without_creating_anything
    Catalog::UNBUILDABLE.each do |name|
      start do |server|
        error = assert_raises(LibTmux::Workspace::ApplyError, name) { Catalog.workspace(name).plan(snapshot: server.snapshot).apply(server: server) }
        assert_equal "LibTmux::Workspace::ConfigError", error.failure_class, name
        assert_empty error.result.created_refs, name
        assert_empty server.list_sessions, name
      end
    end
  end

  def test_the_comparison_reports_a_tree_that_differs
    start do |server|
      Catalog.workspace("3-pane.yaml").plan(snapshot: server.snapshot).apply(server: server)
      @layouts = {server.list_windows.fetch(0).id => "main-vertical"}
      tree = built(server)
      assert_equal wanted("3-pane.yaml"), tree
      refute_equal wanted("4-pane.yaml"), tree
      refute_equal wanted("3-pane.yaml").tap { |expected| expected["windows"][0]["panes"][0]["focus"] = false }, tree
    end
  end
end
