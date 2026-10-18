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
    with_job = "### [libtmux](#{Blocks::GEM_TREE}/libtmux): the core\n"
    assert_empty Blocks.gem_heading_problems(with_job, "control.md", gems: %w[libtmux])
    other_gem = "### [libtmux](#{Blocks::GEM_TREE}/libtmux-async): the core\n"
    refute_empty Blocks.gem_heading_problems(other_gem, "control.md", gems: %w[libtmux])
    bare_colon = "### [libtmux](#{Blocks::GEM_TREE}/libtmux):\n"
    refute_empty Blocks.gem_heading_problems(bare_colon, "control.md", gems: %w[libtmux])
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

  def test_tool_names_may_link_by_reference
    page = "#{Blocks::TOOL_PAGES}/tmux_send/"
    referenced = "- [`tmux_send`][tool-tmux_send]\n\n[tool-tmux_send]: #{page}\n"
    assert_empty Blocks.tool_link_problems(referenced, "control.md", tools: TOOLS)
    undefined = Blocks.tool_link_problems("- [`tmux_send`][tool-tmux_send]\n", "control.md", tools: TOOLS)
    assert_match(/undefined link label/, undefined.first)
    other = "- [`tmux_send`][tool]\n\n[tool]: #{Blocks::TOOL_PAGES}/tmux_capture/\n"
    assert_match(/links to/, Blocks.tool_link_problems(other, "control.md", tools: TOOLS).first)
    bare = Blocks.tool_link_problems("- `tmux_send` reads\n\n[tool]: #{page}\n", "control.md", tools: TOOLS)
    assert_equal 1, bare.length
  end

  def test_reference_links_name_a_definition_and_every_definition_is_used
    Blocks::DOCUMENTS.each do |path|
      assert_empty Blocks.reference_link_problems(Blocks.read(path), path)
    end
    assert_empty Blocks.reference_link_problems("A [`call`][call].\n\n[call]: https://example.test/\n", "control.md")
    mistyped = Blocks.reference_link_problems("A [`call`][cal].\n\n[call]: https://example.test/\n", "control.md")
    assert_equal ["control.md: the link label [cal] has no definition",
      "control.md: the link definition [call] is not used"], mistyped
    fenced = "```ruby\nlist[0][1]\n```\n\n[call]: https://example.test/\n"
    assert_equal ["control.md: the link definition [call] is not used"], Blocks.reference_link_problems(fenced, "control.md")
  end

  def test_contents_links_land_on_headings
    Blocks::DOCUMENTS.each do |path|
      assert_empty Blocks.anchor_problems(Blocks.read(path), path)
    end
    page = "## Quick start\n\n### [`Server#list_sessions`][list]: what tmux has now\n\n" \
      "### Repeat\n\n### Repeat\n\n[a](#quick-start) [b](#serverlist_sessions-what-tmux-has-now) [c](#repeat-1)\n"
    assert_empty Blocks.anchor_problems(page, "control.md")
    missing = Blocks.anchor_problems("## Quick start\n\n[a](#quick-starts)\n", "control.md")
    assert_equal ["control.md: no heading has the anchor #quick-starts"], missing
    in_fence = Blocks.anchor_problems("```ruby\n## Quick start\n```\n\n[a](#quick-start)\n", "control.md")
    refute_empty in_fence
  end

  def test_the_mcp_readme_lists_every_tool_of_the_catalog_in_its_table
    rows = Blocks.read("gems/libtmux-mcp/README.md").lines.grep(/\A\| .*\[`tmux_.* \| (?:Enabled|Disabled) \|/)
    names = rows.flat_map { |row| row.split(" | ").first.scan(/\[`(tmux_[a-z_]+)`\]/).flatten }
    assert_equal TOOLS.sort, names.sort
    assert_equal 4, rows.length
  end

  def test_the_gem_index_keeps_its_rows
    {"README.md" => "[%s](gems/%s/README.md)", "gems/libtmux/README.md" => "[%s](#{Blocks::GEM_TREE}/%s)"}.each do |path, link|
      assert_empty Blocks.gem_index_problems(Blocks.read(path), path, gems: Blocks::GEMS, link: link)
    end
    without = Blocks.read("README.md").lines.reject { |line| line.start_with?("| [libtmux-async]") }.join
    refute_empty Blocks.gem_index_problems(without, "control.md", gems: Blocks::GEMS, link: "[%s](gems/%s/README.md)")
  end

  def test_links_stay_out_of_code_fences
    Blocks::DOCUMENTS.each do |path|
      assert_empty Blocks.fence_link_problems(Blocks.read(path), path)
    end
    linked = "```ruby\nputs 1 # see [docs](https://libtmux.org/)\n```\n"
    refute_empty Blocks.fence_link_problems(linked, "control.md")
    assert_empty Blocks.fence_link_problems("```ruby\nlist[0](x)\n```\n", "control.md")
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
