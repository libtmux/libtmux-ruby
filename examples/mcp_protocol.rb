# frozen_string_literal: true

require "libtmux/mcp"
require "open3"
require "socket"
require_relative "support"

Example.run("mcp_protocol") do |server|
  server.new_session(name: "protocol", command: ["/bin/cat"])
  authored_profile = nil
  Async do |parent|
    LibTmux::Async.open(parent: parent, server: server) do |scope|
      # docs:begin main
      application = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "example")
      sdk = application.sdk_server
      input, client_input = IO.pipe
      client_output, output = IO.pipe
      transport = LibTmux::MCP::StdioTransport.new(server: sdk, parent: parent, input: input, output: output)
      runner = parent.async { transport.run }
      # docs:end main
      send_request = lambda do |id, method, params = {}|
        client_input.write(JSON.generate({jsonrpc: "2.0", id: id, method: method, params: params}) + "\n")
      end
      receive = -> { JSON.parse(parent.with_timeout(0.5) { client_output.gets }) }
      envelope = {"io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => {}}
      send_request.call(1, "server/discover")
      Example.check(receive.call.dig("result", "supportedVersions") == ["2026-07-28"], "protocol discovery failed")
      send_request.call(2, "tools/call", {name: "tmux_capabilities", arguments: {}, _meta: envelope})
      capabilities = receive.call.dig("result", "structuredContent", "data")
      authored_profile = capabilities.fetch("authored_run").fetch("availability")
      Example.check(capabilities.fetch("endpoint") == "example", "endpoint alias differs")
      send_request.call(3, "tools/call", {name: "tmux_snapshot", arguments: {entity: "pane"}, _meta: envelope})
      Example.check(receive.call.dig("result", "structuredContent", "data", "items").length == 1, "protocol read failed")
      Example.check(application.call("tmux_close", {}).structured_content.dig("error", "code") == "policy_denied", "default policy permits mutation")
      cancellations = Queue.new
      sdk.define_custom_method(method_name: "example/wait") do |_, server_context:|
        scope.server.run(["wait-for", "-S", "protocol-ready", ";", "wait-for", "protocol-held"], timeout: 0.5)
        {finished: true}
      rescue LibTmux::Cancelled => failure
        cancellations << failure
        {cancelled: true}
      end
      send_request.call(4, "example/wait", {_meta: envelope})
      scope.server.wait_for("protocol-ready", timeout: 0.5)
      client_input.write(JSON.generate({jsonrpc: "2.0", method: "notifications/cancelled", params: {requestId: 4}}) + "\n")
      send_request.call(5, "tools/call", {name: "tmux_capabilities", arguments: {}, _meta: envelope})
      Example.check(receive.call.fetch("id") == 5, "cancelled request blocked protocol reader")
      failure = parent.with_timeout(0.5) { cancellations.pop }
      Example.check(failure.delivery == :possibly_sent, "cancellation claimed no dispatch")
      Example.raises(Errno::ECHILD) { Process.waitpid(failure.pid, Process::WNOHANG) }
    ensure
      failure = $!
      cleanup = [-> { client_input&.close unless client_input&.closed? },
        -> { runner&.wait(timeout: 0.5) }, -> { transport&.close }, -> { application&.close }]
      cleanup.concat([input, output, client_output].compact.map { |io| -> { io.close unless io.closed? } })
      cleanup.each do |action|
        action.call
      rescue Exception => error
        failure ||= error
      end
      raise failure if failure
    end
  end.wait
  directory = File.dirname(server.endpoint.socket_path)
  setup = File.join(directory, "explicit enrollment.zsh")
  enrollment_arguments = []
  if authored_profile == "conditional"
    ready_path = File.join(directory, "example-ready")
    shell_config = File.join(directory, ".zshrc")
    listener = UNIXServer.new(ready_path)
    File.write(shell_config, <<~ZSH)
      zmodload zsh/net/socket || exit 80
      zsocket '#{listener.path}' || exit 81
      typeset -g example_control=$REPLY
      print -r -- initializing >&$example_control
      IFS= read -r setup_file <&$example_control
      source "$setup_file" || exit 82
      export EXAMPLE_CONTEXT=installed
      PS1=''
      example_ready() { print -r -- ready >&$example_control }
      zle -N zle-line-init example_ready
    ZSH
    shell = server.new_session(name: "enrolled-example", cwd: directory,
      command: ["/usr/bin/env", "ZDOTDIR=#{directory}", "/bin/zsh", "-d", "-i"])
    shell_pane = shell.list_panes.first
    Example.check(IO.select([listener], nil, nil, 0.5), "example shell did not connect")
    channel = listener.accept
    Example.check(IO.select([channel], nil, nil, 0.5) && channel.gets == "initializing\n", "shell setup did not initialize")
    enrollment_arguments = ["--enroll-pane", "#{shell_pane.id}=#{setup}"]
  end
  # docs:begin cli
  executable = Gem.bin_path("libtmux-mcp", "libtmux-mcp")
  Open3.popen3(Gem.ruby, "-W:no-experimental", executable, "--socket", server.endpoint.socket_path,
    "--tmux", Example.executable, "--endpoint", "installed", "--enable-tool", "tmux_create", "--enable-tool", "tmux_send",
    "--enable-tool", "tmux_close", "--enable-tool", "tmux_run", *enrollment_arguments) do |input, output, errors, process|
    request = lambda do |id, method, params = {}|
      input.write(JSON.generate({jsonrpc: "2.0", id: id, method: method, params: params}) + "\n")
      Example.check(IO.select([output], nil, nil, id == 1 ? 1.0 : 0.5), "installed MCP did not return a frame")
      response = JSON.parse(output.gets)
      Example.check(response.fetch("id") == id, "MCP response identity changed")
      response.fetch("result")
    end
    request.call(1, "initialize", {protocolVersion: "2025-11-25", capabilities: {},
      clientInfo: {name: "recipe", version: "1"}})
    input.write(JSON.generate({jsonrpc: "2.0", method: "notifications/initialized"}) + "\n")
    names = request.call(2, "tools/list").fetch("tools").map { |tool| tool.fetch("name") }
    Example.check(names.sort == %w[tmux_capabilities tmux_close tmux_create tmux_run tmux_send tmux_snapshot], "tool policy differs")
    created = request.call(3, "tools/call", {name: "tmux_create", arguments: {
      kind: "session", name: "via-protocol", argv: ["/bin/cat"]}}).fetch("structuredContent")
    Example.check(created.fetch("ok"), "protocol creation failed")
    data = created.fetch("data")
    pane = data.fetch("created").find { |ref| ref.fetch("kind") == "pane" }
    sent = request.call(4, "tools/call", {name: "tmux_send", arguments: {
      target: pane, input: {type: "text", text: "literal;"}}}).fetch("structuredContent")
    Example.check(sent.fetch("data").fetch("completion") == "dispatch_only", "send claimed shell completion")
    target = pane
    if channel
      Example.check(File.stat(setup).mode & 0o777 == 0o600, "enrollment setup permissions differ")
      channel.puts(setup)
      Example.check(IO.select([channel], nil, nil, 0.5) && channel.gets == "ready\n", "shell enrollment was not acknowledged")
      target = pane.merge("id" => shell_pane.id)
    end
    script = 'printf "%s:%s" "$EXAMPLE_CONTEXT" "$TMUX_PANE"; printf "\\000\\377" >&2; exit 9'
    run = request.call(5, "tools/call", {name: "tmux_run", arguments: {
      target: target, script: script, stdout_limit: 128, stderr_limit: 2}}).fetch("structuredContent")
    if channel
      Example.check(run.fetch("ok"), "installed authored run failed")
      result = run.fetch("data")
      Example.check(result.fetch("stdout").fetch("data") == "installed:#{shell_pane.id}", "authored shell context differs")
      Example.check(result.fetch("stderr") == {"encoding" => "base64", "data" => "AP8=", "bytes" => 2, "truncated" => false}, "authored bytes differ")
      Example.check(result.fetch("completion") == {"state" => "exited", "exit_status" => 9, "signal" => nil}, "native completion differs")
      Example.check(result.fetch("authorization").fetch("state") == "authorized", "authorization receipt missing")
    else
      Example.check(run.dig("error", "code") == "unsupported" && run.dig("error", "delivery") == "not_sent", "unsupported enrollment did not refuse")
    end
    closed = request.call(6, "tools/call", {name: "tmux_close", arguments: {target: data.fetch("entity")}})
    Example.check(closed.fetch("structuredContent").fetch("ok"), "protocol close failed")
    input.close
    Example.check(process.join(0.5), "MCP EOF did not retire its process")
    Example.check(process.value.success? && errors.read.empty?, "MCP executable failed")
    Example.check(!File.exist?(setup), "enrollment setup survived EOF")
  end
  # docs:end cli
  shell&.kill
  Example.check(server.list_sessions.size == 1, "CLI EOF changed the borrowed server")
ensure
  [channel, listener].compact.each { |io| io.close unless io.closed? }
  [ready_path, shell_config].compact.each { |path| File.unlink(path) if File.exist?(path) }
end
