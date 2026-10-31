# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/readme_blocks"
require "fileutils"
require "json"
require "libtmux/mcp"
require "open3"
require "shellwords"
require "tmpdir"

# Runs the commands, client configurations and workspace files the READMEs
# print, as written, against tmux servers that live in a private directory.
# Commands that install software or set up the checkout are accounted for
# below; any other command without a verifier fails the test.
class ReadmeCommandsTest < Minitest::Test
  Blocks = LibTmuxTest::ReadmeBlocks
  DEADLINE = 30
  CATALOG = LibTmux::MCP.const_get(:Catalog)

  # What a README says a command shows or does, beyond exiting successfully.
  CLAIMS = {
    /list-windows -t work\z/ => /editor/
  }.freeze

  class Sandbox
    attr_reader :directory, :work

    def initialize
      @directory = Dir.mktmpdir("libtmux-ruby-readme-", "/tmp")
      @work = File.join(directory, "work")
      @variables = {}
      home = File.join(directory, "home")
      bin = File.join(directory, "bin")
      [work, home, bin, File.join(directory, "t")].each { |path| FileUtils.mkdir_p(path) }
      File.symlink(tmux, File.join(bin, "tmux"))
      %w[libtmux-mcp libtmux-workspace].each do |name|
        script = File.join(bin, name)
        File.write(script, "#!/bin/sh\nexec #{Shellwords.join([Gem.ruby, '-W:no-experimental', Gem.bin_path(name, name)])} \"$@\"\n")
        File.chmod(0o755, script)
      end
      @env = {"HOME" => home, "TMPDIR" => directory, "TMUX_TMPDIR" => File.join(directory, "t"),
              "PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", "TMUX" => nil, "TMUX_PANE" => nil,
              "LIBTMUX_SOCKET" => nil, "LIBTMUX_SOCKET_PATH" => nil, "XDG_CONFIG_HOME" => File.join(home, ".config")}
    end

    def tmux
      @tmux ||= begin
        name = ENV.fetch("LIBTMUX_TEST_TMUX", "tmux")
        candidates = name.include?(File::SEPARATOR) ? [name] : ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }
        candidates.find { |path| File.file?(path) && File.executable?(path) } or raise "tmux executable is unavailable"
      end
    end

    Result = Struct.new(:stdout, :stderr, :status)

    def run(*command, input: "")
      Open3.popen3(@env.merge(@variables), *command, chdir: work, pgroup: true) do |stdin, stdout, stderr, thread|
        stdin.write(input)
        stdin.close
        readers = [stdout, stderr].map { |io| Thread.new { io.read } }
        unless thread.join(DEADLINE)
          Process.kill("KILL", -thread.pid)
          thread.join
          raise "#{command.join(' ')} did not finish in #{DEADLINE} seconds"
        end
        Result.new(readers[0].value, readers[1].value, thread.value)
      end
    end

    def shell(command)
      run("/bin/sh", "-c", command)
    end

    def variable(name)
      @variables[name]
    end

    # A page that says "set TMUX_SOCKET to an existing tmux socket" gets one.
    def provide_socket
      socket = File.join(directory, "env.sock")
      created = run(tmux, "-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "existing")
      raise "could not start the TMUX_SOCKET server: #{created.stderr}" unless created.status.success?

      @variables["TMUX_SOCKET"] = socket
    end

    # `NAME=$(...)` keeps its value for the commands after it, as in a shell.
    def assign(command)
      name = command[/\A[A-Z][A-Z0-9_]*/]
      result = shell("#{command}; printf %s \"$#{name}\"")
      @variables[name] = result.stdout if result.status.success?
      result
    end

    # The server binds an enrollment socket under TMPDIR, whose path must stay
    # under the Unix socket limit; CI sets TMPDIR to /tmp for the same reason.
    def mcp(argv, where)
      executable = Gem.bin_path("libtmux-mcp", "libtmux-mcp")
      Open3.popen3(@env.merge(@variables, "TMPDIR" => "/tmp"), Gem.ruby, "-W:no-experimental", executable, *argv, chdir: work) do |stdin, stdout, stderr, thread|
        session = McpSession.new(stdin, stdout, stderr, "#{where}: libtmux-mcp #{argv.join(' ')}")
        session.request("initialize", protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "readme", version: "1"})
        session.notify("notifications/initialized")
        yield session
        stdin.close
        finished = thread.join(DEADLINE)
        Process.kill("KILL", thread.pid) unless finished
        Result.new(stdout.read, stderr.read, finished ? thread.value : nil)
      end
    end

    def close
      sockets = Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.socket?(path) }
      sockets.each { |socket| run(tmux, "-S", socket, "kill-server") }
    ensure
      FileUtils.remove_entry(directory)
    end
  end

  class McpSession
    def initialize(input, output, error, label)
      @input, @output, @error, @label, @id = input, output, error, label, 0
    end

    def notify(method)
      @input.write(JSON.generate({jsonrpc: "2.0", method: method}) + "\n")
    end

    def request(method, **params)
      @id += 1
      @input.write(JSON.generate({jsonrpc: "2.0", id: @id, method: method, params: params}) + "\n")
      loop do
        raise Minitest::Assertion, "#{@label}: no response to #{method}" unless IO.select([@output], nil, nil, DEADLINE)

        line = @output.gets or raise Minitest::Assertion, "#{@label}: output closed during #{method}: #{@error.read}"
        message = JSON.parse(line)
        return message.fetch("result") if message["id"] == @id
      end
    end

    def tools
      request("tools/list").fetch("tools").map { |tool| tool.fetch("name") }
    end

    def capabilities
      request("tools/call", name: "tmux_capabilities", arguments: {}).fetch("structuredContent").fetch("data")
    end
  end

  Blocks::DOCUMENTS.each do |path|
    define_method("test_commands_in_#{path.tr('/.-', '___')}_run_as_written") do
      run_markdown(Blocks.read(path), path)
    end
  end

  def test_mcp_tool_table_states_the_defaults_the_server_serves
    markdown = Blocks.read("gems/libtmux-mcp/README.md")
    table = tool_table(markdown)
    assert_equal CATALOG::NAMES.sort, table.keys.sort
    assert_equal CATALOG::READ_ONLY.sort, table.select { |_, enabled| enabled }.keys.sort
    sandbox = Sandbox.new
    begin
      assert sandbox.run(sandbox.tmux, "-L", "agent", "-f", "/dev/null", "new-session", "-d", "-s", "work").status.success?
      everything = table.reject { |_, enabled| enabled }.keys.flat_map { |name| ["--enable-tool", name] }
      sandbox.mcp(["--socket-name", "agent", *everything], "tool table") { |session| assert_equal table.keys.sort, session.tools.sort }
    ensure
      sandbox.close
    end
  end

  def test_the_runner_rejects_what_the_readmes_must_not_do
    broken = "```console\n$ tmux -L control no-such-command\n```\n"
    assert_match(/no-such-command/, refusal(broken))

    assert_match(/no verifier/, refusal("```console\n$ curl https://example.invalid\n```\n"))

    workspace = "```yaml\nsession_name: a\nwindows:\n  - window_name: a\n    panes: [{}]\n```\n"
    validate = "```console\n$ libtmux-workspace validate workspace.yaml\n```\n"
    assert_match(/output differs/, refusal(workspace + validate + "```text\nWorkspace configuration is invalid.\n```\n"))

    invalid = "```yaml\nsession_name: a\nwindows: []\n```\n"
    assert_match(/validate workspace\.yaml/, refusal(invalid + validate))

    start = "```console\n$ tmux -L control new-session -d\n```\n"
    wrong_default = "| [`tmux_capture`](#{Blocks::TOOL_PAGES}/tmux_capture/) | Enabled | x |\n"
    assert_match(/tool table differs/, refusal(wrong_default + start + "```console\n$ libtmux-mcp --socket-name control\n```\n"))

    assert_match(/Invalid arguments/, refusal(start + "```console\n$ libtmux-mcp --socket-name control --no-such-option\n```\n"))

    assert_match(/does not show a command/, refusal("Prose only.\n"))
  end

  private

  def refusal(markdown)
    assert_raises(Minitest::Assertion) { run_markdown(markdown, "control.md") }.message
  end

  def run_markdown(markdown, where)
    sandbox = Sandbox.new
    yaml = Blocks.fences(markdown).find { |fence| fence.language == "yaml" }
    File.write(File.join(sandbox.work, "workspace.yaml"), yaml.lines.join("\n") + "\n") if yaml
    table = tool_table(markdown)
    sandbox.provide_socket if markdown.include?("$TMUX_SOCKET")
    events = Blocks.steps(markdown).map { |step| [step.line, step] } +
      Blocks.fences(markdown).select { |fence| fence.language == "json" }.map { |fence| [fence.line, fence] }
    ran = false
    events.sort_by(&:first).each do |line, event|
      ran = true
      if event.is_a?(Blocks::Fence)
        configuration = JSON.parse(event.lines.join("\n")).fetch("mcpServers")
        configuration.each_value do |server|
          assert_equal "libtmux-mcp", server.fetch("command"), "#{where}:#{line}: not a libtmux-mcp client entry"
          launch(sandbox, server.fetch("args"), table, "#{where}:#{line}")
        end
      else
        step(sandbox, event, table, "#{where}:#{line}")
      end
    end
    assert ran, "#{where} does not show a command or client configuration to run"
  ensure
    sandbox&.close
  end

  def step(sandbox, step, table, where)
    command = step.command
    words = Blocks.words(command)
    if command.match?(/\A[A-Z][A-Z0-9_]*=/)
      assert sandbox.assign(command).status.success?, "#{where}: #{command}"
    elsif words.first == "gem"
      nil # Names and flags are checked by test/unit/readme_blocks_test.rb; installing needs the network.
    elsif words.first(5) == %w[mise exec -- bundle exec] && words[5] == "ruby" && words[6]&.start_with?("examples/")
      result = sandbox.run(Gem.ruby, "-W:no-experimental", File.join(Blocks::ROOT, words[6]))
      assert result.status.success?, "#{where}: #{command}\n#{result.stderr}"
      assert_equal step.output, result.stdout, "#{where}: output differs from the page" if step.output
    elsif words.first == "mise"
      nil # Checkout setup and builds; test/packaging builds and installs the artifacts.
    elsif %w[claude codex].include?(words.first) && words[1, 2] == %w[mcp add] && words.include?("--")
      server = words.drop(words.index("--") + 1)
      assert_equal "libtmux-mcp", server.first, "#{where}: not a libtmux-mcp client command"
      launch(sandbox, server.drop(1), table, where)
    elsif words.first == "libtmux-mcp"
      launch(sandbox, words.drop(1), table, where)
    elsif %w[tmux libtmux-workspace rm].include?(words.first)
      result = sandbox.shell(command)
      assert result.status.success?, "#{where}: #{command}\n#{result.stdout}#{result.stderr}"
      assert_equal step.output, result.stdout, "#{where}: output differs from the page" if step.output
      inspect_output(command, words, result, where)
    else
      flunk "#{where}: no verifier for the command #{command}"
    end
  end

  def inspect_output(command, words, result, where)
    if words.first == "libtmux-workspace" && words.last == "--version"
      expected = Gem::Specification.load(File.join(Blocks::ROOT, "gems/libtmux-workspace/libtmux-workspace.gemspec")).version.to_s
      assert_equal "#{expected}\n", result.stdout, "#{where}: version differs from the gem"
    end
    if words.include?("--json")
      value = JSON.parse(result.stdout)
      refute value.key?("error"), "#{where}: #{result.stdout}"
      assert value.fetch("success"), "#{where}: #{result.stdout}" if words[1] == "load"
    end
    CLAIMS.each { |pattern, shown| assert_match shown, result.stdout, "#{where}: #{command}" if command.match?(pattern) }
  end

  # Runs `libtmux-mcp ARGS` against the server the page started, over stdio.
  def launch(sandbox, argv, table, where)
    socket = sandbox.variable("TMUX_SOCKET")
    argv = argv.map { |word| word.gsub("$TMUX_SOCKET", socket.to_s) }
    options = argv.each_cons(2).to_h { |flag, value| [flag, value] }
    enabled = CATALOG::READ_ONLY + argv.each_cons(2).filter_map { |flag, value| value if flag == "--enable-tool" }
    endpoint = options.fetch("--endpoint", "local")
    setup = argv.each_cons(2).filter_map { |flag, value| value.split("=", 2).last if flag == "--enroll-pane" }
    setup = setup.map { |name| File.expand_path(name, sandbox.work) }
    served = nil
    result = sandbox.mcp(argv, where) do |session|
      served = session.tools.sort
      assert_equal endpoint, session.capabilities.fetch("endpoint"), "#{where}: --endpoint is not the public alias"
      setup.each do |file|
        assert_equal 0o600, File.stat(file).mode & 0o777, "#{where}: setup file is not private"
        assert File.read(file).start_with?("source "), "#{where}: setup file does not source the helper"
      end
    end
    assert_equal enabled.uniq.sort, served, "#{where}: tools served differ from the tools enabled"
    unless table.empty? || argv.include?("--enable-tool")
      assert_equal table.select { |_, on| on }.keys.sort, served, "#{where}: the tool table differs from the default tools"
    end
    assert_equal 0, result.status&.exitstatus, "#{where}: EOF did not end the server: #{result.stderr}"
    assert_empty result.stderr, "#{where}: the server wrote to stderr"
    setup.each { |file| refute File.exist?(file), "#{where}: setup file survived EOF" }
    flag = options.key?("--socket-name") ? ["-L", options["--socket-name"]] : ["-S", options["--socket"]]
    assert sandbox.run(sandbox.tmux, *flag, "has-session").status.success?, "#{where}: EOF stopped the borrowed daemon"
  end

  # Tool name => enabled by default, from the rows of the Tools | Default table.
  def tool_table(markdown)
    markdown.lines.grep(/\A\| .*\[`tmux_[a-z_]+`\].* \| (?:Enabled|Disabled) \|/).each_with_object({}) do |row, table|
      state = row[/\| (Enabled|Disabled) \|/, 1] == "Enabled"
      row.split(" | ").first.scan(/\[`(tmux_[a-z_]+)`\]/) { |(name)| table[name] = state }
    end
  end
end
