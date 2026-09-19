# Executable recipes

Every linked program loads installed gems, starts an isolated server, asserts
its result and verifies owned-daemon cleanup. The shared
[support module](../examples/support.rb) supplies assertions and the cleanup
wrapper. No program adds checkout paths to Ruby's load path.

Run a program from the repository after installing its required local gems:

```console
$ ruby examples/window_links.rb
```

The artifact suite copies programs outside the checkout and runs them against
each gem's isolated dependency closure. [The manifest](../examples/manifest.json)
owns file discovery and the source regions used below. `scripts/examples
--check` rejects an unlisted program or a changed excerpt.

## Captured queries

[Complete list/filter/exact-one program](../examples/list_filter.rb). A fresh
window does not alter an existing capture; local filtering still works after
the binding closes.

<!-- example: list_filter/main -->
```ruby
session = server.new_session(name: "capture", command: ["/bin/cat"])
session.new_window(name: "second", command: ["/bin/cat"])
snapshot = server.snapshot
panes = snapshot.panes
first = panes.one(id: panes.first.id)
session.new_window(name: "later", command: ["/bin/cat"])
Example.check(panes.size == 2, "captured membership changed")
Example.check(panes.where(id: first.id).one.ref == first.ref, "wrong exact match")
Example.raises(LibTmux::MultipleMatchesError) { panes.one }
Example.check(panes.one_or_nil(id: "%4294967294").nil?, "missing pane was invented")
```
<!-- /example -->

## Layout and bytes

[Complete layout/capture/send program](../examples/layout_io.rb). A control
output event establishes that the literal input has reached the pane before
capture. Binary buffers round-trip without text decoding.

<!-- example: layout_io/main -->
```ruby
receipt = server.new_session(name: "layout", command: ["/bin/cat"], receipt: true)
pane = receipt.pane
second = pane.split(direction: :horizontal, size: "40%", command: ["/bin/cat"])
receipt.window.select_layout("tiled")
Example.check(receipt.window.list_panes.map(&:id).sort == [pane.id, second.id].sort, "assigned pane IDs differ")
server.open_control(session: receipt.entity.ref) do |control|
  control.exchange("display-message -p ready", timeout: 0.5)
  output = control.subscribe(pane_id: pane.id, max_bytes: 8192, max_events: 32)
  literal = "literal; #{'#{pane_id}'} $HOME"
  pane.send_text(literal)
  bytes = "".b
  bytes << output.next(timeout: 0.5).data until bytes.include?(literal)
  Example.check(pane.capture.stdout.include?(literal), "capture lost literal input")
end
payload = "NUL\0\xff\n".b
server.write_buffer(name: "bytes", data: payload)
Example.check(server.read_buffer("bytes").stdout == payload, "buffer bytes changed")
```
<!-- /example -->

## One window at three indexes

[Complete window-link program](../examples/window_links.rb). Window identity
and selection context remain distinct.

<!-- example: window_links/main -->
```ruby
session = server.new_session(name: "links", command: ["/bin/cat"])
window = session.list_windows.fetch(0)
session.link_window(window.ref, index: 4)
session.link_window(window.ref, index: 9)
links = session.list_window_links
Example.check(links.map(&:index) == [0, 4, 9], "link indexes differ")
Example.check(links.map { |link| link.window.ref }.uniq == [window.ref], "window identity split")
Example.check(links.map(&:ref).uniq.length == 3, "link contexts collapsed")
links.find { |link| link.index == 9 }.select
Example.check(session.display('#{window_index}').text == "9\n", "wrong current link")
```
<!-- /example -->

## Async capture and cancellation

[Complete Async program](../examples/async_cancel.rb). A second task captures
while another tmux client waits; cancellation retires that client's process.

<!-- example: async_cancel/main -->
```ruby
Async do |parent|
  LibTmux::Async.open(parent: parent, server: server) do |scope|
    waiting = parent.async do
      scope.server.run(["wait-for", "-S", "ready", ";", "wait-for", "held"], timeout: 0.5)
    rescue LibTmux::Cancelled => error
      error
    end
    scope.server.wait_for("ready", timeout: 0.5)
    captures = scope.map(scope.server.list_panes.map(&:ref), concurrency: 2) do |ref|
      scope.server.pane(ref).capture
    end
    Example.check(captures.all?(&:success?), "sibling captures stalled")
    waiting.cancel
    failure = waiting.wait
    Example.check(failure.is_a?(LibTmux::Cancelled), "cancellation lost")
    Example.check(failure.delivery == :possibly_sent, "cancelled dispatch claimed no effects")
    Example.raises(Errno::ECHILD) { Process.waitpid(failure.pid, Process::WNOHANG) }
  end
end.wait
```
<!-- /example -->

## Control overflow

[Complete control program](../examples/control_overflow.rb). A slow reliable
subscriber fails explicitly; a tail subscriber reports a gap and replies
continue to drain.

<!-- example: control_overflow/main -->
```ruby
server.open_control(session: session.ref) do |control|
  control.exchange("display-message -p ready", timeout: 0.5)
  reliable = control.subscribe(max_events: 1, max_bytes: 1024)
  tail = control.subscribe(mode: :tail, max_events: 1, max_bytes: 1024)
  3.times { |index| window.rename("event#{index}") }
  reply = control.exchange("display-message -p alive", timeout: 0.5)
  Example.check(reply.blocks.last.body == "alive\n", "slow reader blocked commands")
  Example.check(reply.attribution == :boundary_window, "reply overclaims attribution")
  reliable.next(timeout: 0.5)
  Example.raises(LibTmux::SubscriptionOverflow) { reliable.next(timeout: 0.5) }
  gap = tail.next(timeout: 0.5)
  Example.check(gap.kind == :gap && gap.dropped_bytes.positive?, "tail hid lost bytes")
end
```
<!-- /example -->

## Failure inside a group

[Complete group program](../examples/failed_group.rb). The first mutation
survives a later failure. A separate read establishes the missing later effect;
the group result does not invent statuses for its members.

<!-- example: failed_group/main -->
```ruby
group = server.run_group([
  ["set-option", "-g", "@before", "retained"],
  ["select-pane", "-t", "%4294967294"],
  ["set-option", "-g", "@after", "not-executed"]
])
Example.check(!group.success?, "failing group succeeded")
Example.check(group.steps.all? { |step| step.fetch(:outcome) == :unknown }, "invented per-step status")
Example.check(server.options(scope: :session).get("@before").raw == "retained", "earlier effect rolled back")
Example.raises(LibTmux::CommandError) { server.options(scope: :session).get("@after") }
```
<!-- /example -->

## MCP protocol

[Complete MCP program](../examples/mcp_protocol.rb). Real pipe frames exercise
discovery, snapshot reads, default mutation denial and cancellation of an
application-owned WAIT method. The custom WAIT method is a transport probe,
not part of the advertised tmux tool catalog.

<!-- example: mcp_protocol/main -->
```ruby
application = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "example")
sdk = application.sdk_server
input, client_input = IO.pipe
client_output, output = IO.pipe
transport = LibTmux::MCP::StdioTransport.new(server: sdk, parent: parent, input: input, output: output)
runner = parent.async { transport.run }
```
<!-- /example -->

The installed executable also exercises explicitly enabled create, send,
close and authored-run tools. Its complete program creates a zsh pane whose
startup file explicitly sources the CLI's mode-0600 enrollment file, waits
for the authenticated acknowledgement, and checks binary stderr and native
exit status. It closes stdin and verifies enrollment cleanup and borrowed
daemon survival. An unsupported advertised process backend exercises the
structured refusal instead; that is not positive enrollment evidence.

<!-- example: mcp_protocol/cli -->
```ruby
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
```
<!-- /example -->

## Workspace plan, load and failure

[Complete workspace program](../examples/workspace_apply.rb) consumes the
[checked configuration](../examples/workspace.yaml), applies it, then verifies
partial failure and guarded compensation when another layout exceeds available
pane space. It also runs installed CLI validation, planning and loading.

<!-- example: workspace_apply/main -->
```ruby
workspace = LibTmux::Workspace.load(File.join(__dir__, "workspace.yaml"))
plan = workspace.plan(snapshot: server.snapshot)
Example.check(server.list_sessions.size == 1, "planning changed tmux")
result = plan.apply(server: server)
Example.check(result.success?, "workspace apply failed")
Example.check(result.effects.any? { |effect| effect.outcome == :dispatch_only }, "shell dispatch overclaims completion")
crowded = LibTmux::Workspace.parse(JSON.generate({
  session_name: "crowded", windows: [{window_name: "small", panes: Array.new(40) { {} }}]
}), format: :json, base_directory: __dir__)
error = Example.raises(LibTmux::Workspace::ApplyError) do
  crowded.plan.apply(server: server, compensate: true)
end
Example.check(!error.result.created_refs.empty?, "failure lost partial creation ledger")
Example.check(error.result.compensation == :completed, "owned compensation failed")
Example.check(server.list_sessions.map(&:ref).include?(borrowed.ref), "borrowed session was removed")
```
<!-- /example -->
