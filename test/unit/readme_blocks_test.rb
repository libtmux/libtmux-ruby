# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/readme_blocks"
require "libtmux/mcp/cli"
require "libtmux/workspace/cli"
require "stringio"

class ReadmeBlocksTest < Minitest::Test
  Blocks = LibTmuxTest::ReadmeBlocks
  TOOLS = LibTmux::MCP.const_get(:Catalog)::NAMES

  def test_console_blocks_hold_one_command_each
    Blocks::DOCUMENTS.each do |path|
      assert_empty Blocks.console_problems(Blocks.read(path), path)
    end
    two = "```console\n$ one\n$ two\n```\n"
    output = "```console\n$ one\nprinted\n```\n"
    [two, output].each do |markdown|
      refute_empty Blocks.console_problems(markdown, "control.md")
    end
    continued = Blocks.fences("```console\n$ libtmux-workspace load \\\n    --json x\n```\n").first
    assert_equal "libtmux-workspace load --json x", Blocks.command(continued)
  end

  def test_gem_installs_name_gems_of_this_repository_and_pass_the_prerelease_flag
    versions = Blocks::GEMS.map { |name| Gem::Specification.load(File.join(Blocks::ROOT, "gems", name, "#{name}.gemspec")).version.to_s }
    Blocks::DOCUMENTS.each do |path|
      assert_empty Blocks.gem_install_problems(Blocks.read(path), path, gems: Blocks::GEMS, versions: versions)
    end
    unknown = "```console\n$ gem install libtmux-nothing --pre\n```\n"
    unpinned = "```console\n$ gem install libtmux-mcp\n```\n"
    refute_empty Blocks.gem_install_problems(unknown, "control.md", gems: Blocks::GEMS, versions: versions)
    refute_empty Blocks.gem_install_problems(unpinned, "control.md", gems: Blocks::GEMS, versions: versions)
    assert_empty Blocks.gem_install_problems(unpinned, "control.md", gems: Blocks::GEMS, versions: %w[1.0.0])
  end

  def test_root_and_core_readmes_link_every_gem_directory_from_a_heading
    %w[README.md gems/libtmux/README.md].each do |path|
      assert_empty Blocks.gem_heading_problems(Blocks.read(path), path, gems: Blocks::GEMS)
    end
    plain = "### libtmux\n\n[libtmux](#{Blocks::GEM_TREE}/libtmux)\n"
    refute_empty Blocks.gem_heading_problems(plain, "control.md", gems: %w[libtmux])
    Blocks::GEMS.each do |name|
      assert File.file?(File.join(Blocks::ROOT, "gems", name, "README.md")), "#{name} has no README to link"
    end
  end

  def test_tool_names_in_tables_and_lists_link_to_their_pages
    Blocks::DOCUMENTS.each do |path|
      assert_empty Blocks.tool_link_problems(Blocks.read(path), path, tools: TOOLS)
    end
    page = "#{Blocks::TOOL_PAGES}/tmux_send/"
    assert_empty Blocks.tool_link_problems("| [`tmux_send`](#{page}) | x |\n", "control.md", tools: TOOLS)
    bare = Blocks.tool_link_problems("| `tmux_send` | x |\n- `tmux_snapshot` reads\n", "control.md", tools: TOOLS)
    assert_equal 2, bare.length
    wrong = Blocks.tool_link_problems("- [`tmux_send`](#{Blocks::TOOL_PAGES}/tmux_capture/)\n", "control.md", tools: TOOLS)
    assert_match(/links to/, wrong.first)
    assert_empty Blocks.tool_link_problems("Prose may name `tmux_send` once.\n", "control.md", tools: TOOLS)
  end

  def test_the_mcp_readme_documents_every_tool_of_the_catalog_once
    rows = Blocks.read("gems/libtmux-mcp/README.md").lines.grep(/\A\| \[`tmux_/)
    names = rows.map { |row| row[/\[`(tmux_[a-z_]+)`\]/, 1] }
    assert_equal TOOLS.sort, names.sort
  end

  def test_documented_flags_belong_to_the_executable
    {
      "libtmux-mcp" => [LibTmux::MCP::CLI, "gems/libtmux-mcp/README.md"],
      "libtmux-workspace" => [LibTmux::Workspace::CLI, "gems/libtmux-workspace/README.md"]
    }.each do |program, (cli, own)|
      help = StringIO.new
      assert_equal 0, cli.run(["--help"], out: help, err: StringIO.new)
      Blocks::DOCUMENTS.each do |path|
        problems = Blocks.flag_problems(Blocks.read(path), path, program: program, help: help.string, prose: path == own)
        assert_empty problems
      end
      invented = "```console\n$ #{program} --no-such-option\n```\n"
      refute_empty Blocks.flag_problems(invented, "control.md", program: program, help: help.string)
      refute_empty Blocks.flag_problems("Pass `--no-such-option` to it.\n", "control.md", program: program, help: help.string, prose: true)
    end
  end
end
