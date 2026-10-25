<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Ruby">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux

Drive tmux from Ruby: [sessions][session], [windows][window] and [panes][pane]
as handles, [snapshots][snapshot] you filter in plain Ruby, and
[control connections][controlconnection] that report what tmux does.

[API reference](https://libtmux.org/en/ruby/latest/reference/) ·
[Guides](https://libtmux.org/en/ruby/latest/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux)

</div>

Part of [libtmux for Ruby](https://github.com/libtmux/libtmux-ruby#readme).
This gem is the core; the [packages below](#packages) build on it.

[Create][server-new_session] and [split][pane-split] windows,
[read][server-snapshot] and [filter][selection-where] what a server holds, and
[type into a pane][pane-send_text] and capture what it shows.

It suits scripts, tests that need a real tmux, and tools that drive a terminal
program. [Cancel][cancellation-cancel] a request that is waiting, and
[follow events][controlconnection-subscribe] as tmux emits them.

**Contents** — [Quick start](#quick-start) ·
[Find things](#find-sessions-windows-and-panes) ·
[Create](#create-sessions-windows-and-panes) ·
[Type and read](#type-into-a-pane-and-read-it-back) ·
[Your own server](#use-the-tmux-server-you-already-run) ·
[Cancel](#wait-time-out-and-cancel) ·
[Link windows](#link-a-window-into-several-sessions) ·
[Options](#read-and-set-options-and-hooks) ·
[Watch tmux](#watch-tmux-change) ·
[Groups](#run-several-commands-in-order) ·
[Packages](#packages) · [Leaves out](#what-it-leaves-out) ·
[Support](#support-and-status) · [Documentation](#documentation)

## Quick start

Install the gem. It needs Ruby 3.3 or newer and tmux 3.3a or newer on
`PATH`:

```console
$ gem install libtmux
```

This program creates a session, adds a window, splits it, and prints each
window with its panes. [`Server.start`][server-start] closes its private tmux
server when the block exits, and the snapshot stays readable afterward:

<!-- example: quickstart/main -->
```ruby
require "libtmux"

snapshot = LibTmux::Server.start do |server|
  session = server.new_session(name: "work", window_name: "main", command: ["/bin/cat"])
  window = session.new_window(name: "logs", command: ["/bin/cat"])
  window.split(direction: :horizontal, size: "40%", command: ["/bin/cat"])

  server.snapshot
end

snapshot.windows.each do |window|
  puts "#{window.name}: #{window.panes.map(&:id).join(', ')}"
end
```
<!-- /example -->

It prints:

```text
main: %0
logs: %1, %2
```

Requiring the gem starts no tmux process, scheduler or MCP server.
[`Server.start`][server-start] gives its tmux server a socket and an empty
configuration of its own, so it never touches a tmux you already use.

## Find sessions, windows, and panes

### [`Server#list_sessions`][server-list_sessions]: what tmux has now

One call asks tmux for every session and returns frozen handles in numeric ID
order. [`list_windows`][server-list_windows] and
[`list_panes`][server-list_panes] are its siblings, and
[`Session#list_windows`][session-list_windows] and
[`Window#list_panes`][window-list_panes] narrow them:

<!-- example: api_list_sessions/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  server.new_session(name: "work", command: ["/bin/cat"])
  server.new_session(name: "logs", command: ["/bin/cat"])
  sessions = server.list_sessions
  puts "sessions: #{sessions.map(&:id).sort.join(', ')}"
end
```
<!-- /example -->

It runs on a private server and prints:

```text
sessions: $0, $1
```

An empty array means tmux answered with nothing to list. A listing that fails
raises [`CommandError`][commanderror].

### [`Server#snapshot`][server-snapshot]: one read, many queries

Read the server once, then filter that read with
[`where`][selection-where], [`select`][selection-select],
[`one`][selection-one] and [`one_or_nil`][selection-one_or_nil]. These queries
make no tmux calls. Continue with the snapshot from the quick start:

<!-- example: quickstart/queries -->
```ruby
panes = snapshot.panes
active_ids = panes.where(active: true).map(&:id)
wide_panes = panes.select { |pane| pane.width >= 40 }
panes_by_window = panes.group_by { |pane| pane.window.name }

logs = snapshot.windows.one(name: "logs")
missing = snapshot.windows.one_or_nil(name: "missing")
```
<!-- /example -->

`one` raises [`NoMatchError`][nomatcherror] or
[`MultipleMatchesError`][multiplematcheserror] unless exactly one record
matches. `one_or_nil` returns `nil` for no match and still rejects duplicates.

A selection keeps the membership it captured, so call `server.snapshot` again
to read later changes. The [field catalog](../../docs/reference/fields.md)
lists every query field and wire name.

### [`Server#search_panes`][server-search_panes]: the matching panes in one call

`search_panes` captures the server and answers a selection of the panes whose
fields match `where:`. [`explain_panes`][server-explain_panes] shows the plan
without running tmux. This program also uses the snapshot queries above:

<!-- example: api_query/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  work = server.new_session(name: "work", command: ["/bin/cat"], receipt: true)
  server.new_session(name: "logs", command: ["/bin/cat"])
  snapshot = server.snapshot
  session = snapshot.sessions.where(name: "work").one
  puts "matching session: #{session.name}"
  missing = snapshot.sessions.one_or_nil(name: "missing")
  puts "missing session: #{missing.nil?}"
  panes = server.search_panes(where: {id: work.pane.id})
  puts "matching pane: #{panes.one.id}"
end
```
<!-- /example -->

It prints:

```text
matching session: work
missing session: true
matching pane: %0
```

## Create sessions, windows, and panes

### [`Server#new_session`][server-new_session]: a session and its first window

`new_session` starts a detached session that runs `command:`, an argv array.
Ask for a receipt to read the IDs tmux assigned to the session, window and
pane:

<!-- example: api_new_session/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  created = server.new_session(
    name: "work", window_name: "main", command: ["/bin/cat"], receipt: true
  )
  puts "session: #{created.entity.id}"
  puts "window: #{created.window.id}"
  puts "pane: #{created.pane.id}"
end
```
<!-- /example -->

It prints:

```text
session: $0
window: @0
pane: %0
```

Creation returns once tmux has assigned the IDs. It says nothing about whether
the program started or exited cleanly.

### [`Session#new_window`][session-new_window]: add a window

[`Pane#split`][pane-split] and [`Window#split`][window-split] add panes the
same way. A new window takes a `name:` and the same `command:` as a session:

<!-- example: api_new_window/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  session = server.new_session(name: "work", command: ["/bin/cat"])
  window = session.new_window(name: "logs", command: ["/bin/cat"])
  puts "window: #{window.snapshot.name}"
  puts "session windows: #{session.list_windows.length}"
end
```
<!-- /example -->

It prints:

```text
window: logs
session windows: 2
```

- `cwd:` names a directory on the machine running Ruby, and is checked before
  the command is sent.
- `environment:` is a String-to-String map of literal values.
- `new_window(index:)` refuses a slot that is taken.
- [`Pane#split`][pane-split] targets that exact pane, and `size:` is a cell
  count or a percentage string such as `"40%"`.
- New windows and splits keep focus unless you pass `focus: true`.

The full contract is in [Creation][behavior-creation].

## Type into a pane and read it back

### [`Pane#send_text`][pane-send_text]: type, then read what the pane showed

`send_text` types literal text, and [`send_keys`][pane-send_keys] sends tmux key
names such as `Enter`. [`Pane#capture`][pane-capture] reads the screen.

To wait for output, poll the pane until the line appears. A
[control connection][server-open_control] reports it as an event instead, but
needs tmux 3.7 or newer:

<!-- example: api_capture/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  created = server.new_session(
    name: "capture", command: ["/bin/sh"],
    environment: {"ENV" => "/dev/null"}, receipt: true
  )
  pane = created.pane
  pane.send_text("printf '\\nlibtmux capture ready\\n'")
  pane.send_keys("Enter")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
  captured = pane.capture.stdout.lines(chomp: true)
  until captured.include?("libtmux capture ready")
    raise "Output did not arrive within five seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.05
    captured = pane.capture.stdout.lines(chomp: true)
  end
  raise "Expected output is absent from the pane" unless captured.include?("libtmux capture ready")
  puts "libtmux capture ready"
end
```
<!-- /example -->

It prints:

```text
libtmux capture ready
```

- Sending input does not show that the shell finished the command.
- `capture` returns the visible screen. `start:` and `finish:` choose a range,
  and `join:` joins wrapped lines.
- `escapes:`, `escape_bytes:`, `preserve_trailing:` and `trim_trailing:` change
  the bytes it returns.
- `mode_screen:`, `alternate:` and `pending:` read a copy-mode screen, the saved
  screen and an unfinished escape sequence. Pass at most one.
- Binary buffers keep their trailing newlines. See
  [`write_buffer`][server-write_buffer] and
  [`read_buffer`][server-read_buffer] in the
  [layout and bytes recipe](../../docs/recipes.md#layout-and-bytes).

The full contract is in [Pane input and capture][behavior-capture].

## Use the tmux server you already run

### [`Server.new`][server-new]: borrow a daemon

[`Server.open`][server-open] and [`Server.new`][server-new] bind an endpoint
that already exists. Closing the binding retires its clients and leaves the
daemon running; [`Server#kill`][server-kill] stops it.

The outer [`Server.start`][server-start] block here only supplies a daemon to
borrow:

<!-- example: api_server/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |owner|
  owner.new_session(name: "work", command: ["/bin/cat"])
  server = LibTmux::Server.new(endpoint: owner.endpoint)
  begin
    puts "connected sessions: #{server.list_sessions.length}"
  ensure
    server.close
  end
  puts "sessions after client close: #{owner.list_sessions.length}"
end
```
<!-- /example -->

It prints:

```text
connected sessions: 1
sessions after client close: 1
```

- [`Endpoint.new`][endpoint-new] takes an explicit socket path or socket name.
  [`Endpoint.from_env`][endpoint-from_env] is the opt-in for `$TMUX`.
- A binding keeps a private link to the socket it bound, so commands never
  reach a different daemon that later takes the same path.
- A ref is valid on the server that issued it. Another server raises
  [`TargetNotFoundError`][targetnotfounderror].

See [ownership and errors](../../docs/ownership-errors.md).

## Wait, time out, and cancel

### [`Cancellation.new`][cancellation-new]: wake a request that is waiting

Typed operations take `timeout:` and `cancel:`. Pass a
[`Cancellation`][cancellation] token as `cancel:`, call
[`cancel`][cancellation-cancel] from another thread to wake the request, join
its callers, then [`close`][cancellation-close] the token:

<!-- example: api_cancellation/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  server.new_session(name: "work", command: ["/bin/cat"])
  cancellation = LibTmux::Cancellation.new
  waiting = Thread.new do
    server.run(["wait-for", "-S", "ready", ";", "wait-for", "held"], timeout: 5, cancel: cancellation)
  rescue LibTmux::Cancelled => error
    error
  end
  server.wait_for("ready", timeout: 5)
  cancellation.cancel
  failure = waiting.value
  puts "request: #{failure.class}"
  puts "delivery: #{failure.delivery}"
  cancellation.close
end
```
<!-- /example -->

It prints:

```text
request: LibTmux::Cancelled
delivery: possibly_sent
```

[`Cancelled`][cancelled] reports `delivery` as `:not_sent` or `:possibly_sent`.
Cancelling does not undo what tmux already queued.

The [plain-Ruby recipe](../../examples/cancel.rb) also checks that the client
was reaped. The contracts are in
[Cancellation tokens][behavior-cancellation] and
[ownership and errors](../../docs/ownership-errors.md).

## Link a window into several sessions

### [`Session#link_window`][session-link_window]: one window at several indexes

A [`WindowLink`][windowlink] keeps a session, an index and a window ID
together, so a window linked twice stays one window. `link_window` needs an
explicit `index:`:

<!-- example: api_link_window/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  session = server.new_session(name: "links", command: ["/bin/cat"])
  window = session.list_windows.fetch(0)
  session.link_window(window.ref, index: 4)
  session.link_window(window.ref, index: 9)
  links = session.list_window_links
  puts "indexes: #{links.map(&:index).join(', ')}"
  puts "windows: #{links.map { |link| link.window.id }.uniq.join(', ')}"
end
```
<!-- /example -->

It prints:

```text
indexes: 0, 4, 9
windows: @0
```

- Select, unlink, move, swap and display check the whole link identity in the
  same tmux queue turn as the operation.
- A hook that waits before dispatch cannot turn a stale link into its
  replacement.
- Rewriting command aliases during an operation is outside that guarantee, so
  coordinate configuration changes.

The contract is in [Window links][behavior-window-links], and the
[linked-windows recipe](../../docs/recipes.md#one-window-at-three-indexes)
runs this at three indexes.

## Read and set options and hooks

### [`Session#options`][session-options]: a value with its inheritance

[`Options#set`][options-set] writes an option at the scope of its accessor.
[`Options#get`][options-get] reads it back as an
[`OptionValue`][optionvalue], and [`as`][optionvalue-as] converts it strictly.
[`Hooks#set`][hooks-set] stores a tmux command:

<!-- example: api_options/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  session = server.new_session(name: "work", command: ["/bin/cat"])
  session.options.set("history-limit", 5000)
  limit = session.options.get("history-limit")
  puts "history-limit: #{limit.as(:integer)}"
  puts "inherited: #{limit.inherited?}"
  session.hooks.set("after-new-window", command: "display-message created")
  puts "hook: #{session.hooks.get('after-new-window').as(:string)}"
end
```
<!-- /example -->

It prints:

```text
history-limit: 5000
inherited: false
hook: display-message created
```

- An [`OptionValue`][optionvalue] keeps the raw bytes, whether the value is
  inherited, and the array index. `as` takes `:bytes`, `:string`, `:integer` or
  `:boolean`.
- A missing array index raises [`NoMatchError`][nomatcherror], and a present
  empty value stays present.
- Reading an array without an index raises
  [`MultipleMatchesError`][multiplematcheserror] when it has several entries.
- Hook values stay tmux command strings, and indexed hooks run in index order.

The contracts are in [Options and hooks][behavior-options] and
[Option values][behavior-option-values].

## Watch tmux change

### [`Server#open_control`][server-open_control]: events as they happen

A [`ControlConnection`][controlconnection] runs a command with
[`exchange`][controlconnection-exchange] and streams what tmux reports through
[`subscribe`][controlconnection-subscribe]. The subscription's
[`next`][controlsubscription-next] waits for the next
[`ControlEvent`][controlevent]:

<!-- example: api_control/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  session = server.new_session(name: "work", command: ["/bin/cat"])
  window = session.list_windows.fetch(0)
  server.open_control(session: session.ref) do |control|
    reply = control.exchange("display-message -p ready", timeout: 5)
    puts "reply: #{reply.blocks.last.body.strip}"
    events = control.subscribe(max_events: 64, max_bytes: 65_536)
    window.rename("renamed")
    event = events.next(timeout: 5) until event&.raw&.start_with?("%window-renamed")
    puts "event: #{event.raw.strip}"
  end
end
```
<!-- /example -->

It prints:

```text
reply: ready
event: %window-renamed @0 renamed
```

- `exchange` answers a [`GuardedReply`][guardedreply]. It holds the blocks seen
  between two boundaries, and a hook can print into the same interval.
- A subscription is bounded. A reliable one raises
  [`SubscriptionOverflow`][subscriptionoverflow] when it falls behind, and a
  tail one reports the lost range as a `:gap` event.
- [`pause_output`][controlconnection-pause_output] and
  [`resume_output`][controlconnection-resume_output] return a
  [`GuardedReply`][guardedreply]. A reply does not show that the action took
  effect.
- To reconnect, close the old connection and pass it as
  `open_control(session: ref, reconnect: old_connection)`. The replacement has
  a new `generation`, and every new subscription starts with a `:reconnect`
  gap. Nothing is replayed.

The contracts are in [Control connections][behavior-control], and the
[control overflow recipe](../../docs/recipes.md#control-overflow) runs both
subscription modes.

## Run several commands in order

### [`Server#run_group`][server-run_group]: several commands through one client

A group submits several tmux commands in order through one client. The
[`GroupResult`][groupresult] holds one aggregate status, and each step reports
`unknown`:

<!-- example: api_run_group/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  server.new_session(name: "work", command: ["/bin/cat"])
  group = server.run_group([
    ["set-option", "-g", "@before", "kept"],
    ["select-pane", "-t", "%4294967294"],
    ["set-option", "-g", "@after", "never run"]
  ])
  puts "success: #{group.success?}"
  puts "steps: #{group.steps.map { |step| step.fetch(:outcome) }.join(', ')}"
  puts "@before: #{server.options(scope: :session).get('@before').as(:string)}"
end
```
<!-- /example -->

It prints:

```text
success: false
steps: unknown, unknown, unknown
@before: kept
```

The first command keeps its effect when the second fails, and the third never
runs. The [group recipe](../../docs/recipes.md#failure-inside-a-group) checks
the same.

## Packages

Start with `libtmux`. Add the companion for your caller:

| Gem | Require | Use it for |
| --- | --- | --- |
| [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux) | `libtmux` | Blocking scripts, snapshots, and control connections |
| [libtmux-async](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-async) | `libtmux/async` | Concurrent commands and bounded streams in Async tasks |
| [libtmux-mcp](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-mcp) | `libtmux/mcp` | An MCP server with explicit endpoints and tool policy |
| [libtmux-workspace](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-workspace) | `libtmux/workspace` | YAML/JSON workspace plans and a CLI to apply them |

### [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux): the core

This gem: blocking [server][server], [session][session], [window][window] and
[pane][pane] handles, immutable [snapshots][snapshot], and
[control connections][controlconnection]. The sections above run against it.

[API reference](https://libtmux.org/en/ruby/latest/reference/) ·
[Guides](https://libtmux.org/en/ruby/latest/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux)

### [libtmux-async](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-async): concurrent commands

Concurrent commands and bounded control streams inside an Async task that your
application owns. Require `libtmux/async`, then open a scope with
[`LibTmux::Async.open`][async-open].

[API reference](https://libtmux.org/en/ruby/latest/reference/libtmux-async/) ·
[Guide](https://libtmux.org/en/ruby/latest/guides/async/) ·
[RubyGems](https://rubygems.org/gems/libtmux-async)

```console
$ gem install libtmux-async
```

Capture every pane concurrently with [`Scope#map`][async-scope-map]. `server`
is an open [`LibTmux::Server`][server]:

<!-- example: async_cancel/map -->
```ruby
Async do |parent|
  LibTmux::Async.open(parent: parent, server: server) do |scope|
    refs = scope.server.list_panes.map(&:ref)
    screens = scope.map(refs, concurrency: 2) { |ref| scope.server.pane(ref).capture }
    Example.check(screens.length == refs.length && screens.all?(&:success?), "concurrent captures failed")
  end
end.wait
```
<!-- /example -->

### [libtmux-mcp](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-mcp): a tmux server for MCP clients

An MCP server over stdio for one tmux server, with an explicit tool policy.
Installs `libtmux-mcp`; require `libtmux/mcp` to embed it through
[`LibTmux::MCP::Application`][mcp-application].

[API reference](https://libtmux.org/en/ruby/latest/mcp/reference/) ·
[Tools](https://libtmux.org/en/ruby/latest/mcp/tools/) ·
[Guides](https://libtmux.org/en/ruby/latest/mcp/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux-mcp)

```console
$ gem install libtmux-mcp
```

The server borrows a tmux server that is already running. Start one on a
socket of its own:

```console
$ tmux -L agent new-session -d -s work
```

Add the server to Claude Code. Until you enable more tools, it serves
[`tmux_capabilities`][tool-tmux_capabilities] and
[`tmux_snapshot`][tool-tmux_snapshot]:

```console
$ claude mcp add tmux -- libtmux-mcp --socket-name agent --endpoint dev
```

The [MCP README](../libtmux-mcp/README.md) covers other clients, every tool and
authored shell commands.

### [libtmux-workspace](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-workspace): YAML workspaces

YAML or JSON workspaces, validated, planned offline and applied to an open
server. Installs `libtmux-workspace`; require `libtmux/workspace` to use it
from Ruby through [`LibTmux::Workspace`][workspace].

[API reference](https://libtmux.org/en/ruby/latest/workspace/reference/) ·
[Command reference](https://libtmux.org/en/ruby/latest/workspace/cli/) ·
[Guides](https://libtmux.org/en/ruby/latest/workspace/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux-workspace)

```console
$ gem install libtmux-workspace
```

Save this workspace as `workspace.yaml`:

<!-- example: workspace/config -->
```yaml
session_name: work
environment:
  PROJECT_MODE: development
windows:
  - window_name: editor
    window_index: 1
    layout: tiled
    panes:
      - shell_command: printf 'editor ready\n'
      - {}
```
<!-- /example -->

Check it without contacting tmux:

```console
$ libtmux-workspace validate workspace.yaml
```

```text
Workspace configuration is valid.
```

The [workspace README](../libtmux-workspace/README.md) loads it into a running
server and lists every option.

## What it leaves out

- **Live objects.** A [snapshot record][snapshot] is what tmux said when you
  read it, and a [handle][server-list_sessions] reads tmux again each time you
  list. See [Captured records][behavior-records] and
  [Live handles][behavior-live-handles].
- **A terminal emulator.** [`Pane#capture`][pane-capture] returns the bytes
  tmux holds for the screen, with the flags above to shape them.
- **An implied server.** [`Endpoint.new`][endpoint-new] needs an explicit
  socket, and no API in the recipes uses the default server.
- **Replay.** A reconnected control connection reports a gap and never replays
  requests or missed output. See [Control flow][behavior-control-flow].
- **Transactions.** A [group][server-run_group] runs in order and keeps the
  effects of the steps before a failure.
- **Whole-program typing.** RBS declarations ship with the gem and selected
  installed calls are checked. See [Signature proof][behavior-signature].

## Support and status

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelog marks each break. Pin an exact version to avoid one.
See the [changelog](../../CHANGELOG.md).

- **Ruby 3.3 or newer.** The gem depends on `json`, `tmpdir`, `securerandom`,
  `fiddle` and `io-console`.
- **tmux 3.3a or newer.** Unpatched 3.3 is below the minimum. A
  [server handle][server] checks the connected daemon's release before it sends
  a command, and refuses an older daemon even when its client is newer.
- **Control connections need tmux 3.7 or newer.** An older daemon refuses
  [`open_control`][server-open_control] before a control client attaches.
  Subprocess operations and snapshots do not need it. The
  [optional feature table](../../docs/reference/behavior.md#optional-tmux-features)
  lists the other per-release requirements.
- **Linux, including WSL, and macOS.** The [compatibility workflow][compat]
  runs Ruby 3.3, 3.4 and 4.0 with tmux 3.3a through 3.8 on Ubuntu 24.04.
  macOS is supported on a best-effort basis, and CI coverage for it is highly
  limited.
- **tmux master and old daemons.** On Ubuntu the workflow also runs the suite
  against a pinned tmux master, and checks that tmux 3.0a, 3.1c, 3.2a and 3.3
  daemons are refused.
- **Per-revision results.** Read the workflow's results for your revision
  before relying on one combination.

## Documentation

| | |
| --- | --- |
| [Reference](https://libtmux.org/en/ruby/latest/reference/) | Every public class and method, one page each |
| [Guides](https://libtmux.org/en/ruby/latest/guides/) | Getting started, server bindings and the Async scope |
| [Recipes](../../docs/recipes.md) | Complete programs with checked excerpts |
| [Execution modes](../../docs/modes.md) | Blocking calls, Async tasks and control subscriptions |
| [Ownership and errors](../../docs/ownership-errors.md) | What close and failure mean |
| [Public behavior](../../docs/reference/behavior.md) | Defaults, ownership, blocking and failure of each call |
| [Field catalog](../../docs/reference/fields.md) | Query fields and wire names |
| [Public methods](../../docs/reference/api.md) | Each exported method, its source and its contract |
| [Contributing](../../.github/CONTRIBUTING.md) | Local builds, checks and the test loops |

MIT. See [LICENSE](LICENSE).

[async-open]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-open/
[async-scope-map]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-scope-map/
[behavior-cancellation]: ../../docs/reference/behavior.md#cancellation-tokens
[behavior-capture]: ../../docs/reference/behavior.md#pane-input-and-capture
[behavior-control]: ../../docs/reference/behavior.md#control-connections
[behavior-control-flow]: ../../docs/reference/behavior.md#control-flow
[behavior-creation]: ../../docs/reference/behavior.md#creation
[behavior-live-handles]: ../../docs/reference/behavior.md#live-handles
[behavior-option-values]: ../../docs/reference/behavior.md#option-values
[behavior-options]: ../../docs/reference/behavior.md#options-and-hooks
[behavior-records]: ../../docs/reference/behavior.md#captured-records
[behavior-signature]: ../../docs/reference/behavior.md#signature-proof
[behavior-window-links]: ../../docs/reference/behavior.md#window-links
[cancellation]: https://libtmux.org/en/ruby/latest/reference/libtmux-cancellation/
[cancellation-cancel]: https://libtmux.org/en/ruby/latest/reference/libtmux-cancellation-cancel/
[cancellation-close]: https://libtmux.org/en/ruby/latest/reference/libtmux-cancellation-close/
[cancellation-new]: https://libtmux.org/en/ruby/latest/reference/libtmux-cancellation-new/
[cancelled]: https://libtmux.org/en/ruby/latest/reference/libtmux-cancelled/
[commanderror]: https://libtmux.org/en/ruby/latest/reference/libtmux-commanderror/
[compat]: https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml
[controlconnection]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection/
[controlconnection-exchange]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection-exchange/
[controlconnection-pause_output]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection-pause_output/
[controlconnection-resume_output]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection-resume_output/
[controlconnection-subscribe]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection-subscribe/
[controlevent]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlevent/
[controlsubscription-next]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlsubscription-next/
[endpoint-from_env]: https://libtmux.org/en/ruby/latest/reference/libtmux-endpoint-from_env/
[endpoint-new]: https://libtmux.org/en/ruby/latest/reference/libtmux-endpoint-new/
[groupresult]: https://libtmux.org/en/ruby/latest/reference/libtmux-groupresult/
[guardedreply]: https://libtmux.org/en/ruby/latest/reference/libtmux-guardedreply/
[hooks-set]: https://libtmux.org/en/ruby/latest/reference/libtmux-hooks-set/
[mcp-application]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application/
[multiplematcheserror]: https://libtmux.org/en/ruby/latest/reference/libtmux-multiplematcheserror/
[nomatcherror]: https://libtmux.org/en/ruby/latest/reference/libtmux-nomatcherror/
[options-get]: https://libtmux.org/en/ruby/latest/reference/libtmux-options-get/
[options-set]: https://libtmux.org/en/ruby/latest/reference/libtmux-options-set/
[optionvalue]: https://libtmux.org/en/ruby/latest/reference/libtmux-optionvalue/
[optionvalue-as]: https://libtmux.org/en/ruby/latest/reference/libtmux-optionvalue-as/
[pane]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-14z6/
[pane-capture]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-capture/
[pane-send_keys]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-send_keys/
[pane-send_text]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-send_text/
[pane-split]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-split/
[selection-one]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one/
[selection-one_or_nil]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one_or_nil/
[selection-select]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-select/
[selection-where]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-where/
[server]: https://libtmux.org/en/ruby/latest/reference/libtmux-server/
[server-explain_panes]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-explain_panes/
[server-kill]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-kill/
[server-list_panes]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-list_panes/
[server-list_sessions]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-list_sessions/
[server-list_windows]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-list_windows/
[server-new]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-new/
[server-new_session]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-new_session/
[server-open]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-open/
[server-open_control]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-open_control/
[server-read_buffer]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-read_buffer/
[server-run_group]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-run_group/
[server-search_panes]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-search_panes/
[server-snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-snapshot/
[server-start]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-start/
[server-write_buffer]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-write_buffer/
[session]: https://libtmux.org/en/ruby/latest/reference/libtmux-session-nvps/
[session-link_window]: https://libtmux.org/en/ruby/latest/reference/libtmux-session-link_window/
[session-list_windows]: https://libtmux.org/en/ruby/latest/reference/libtmux-session-list_windows/
[session-new_window]: https://libtmux.org/en/ruby/latest/reference/libtmux-session-new_window/
[session-options]: https://libtmux.org/en/ruby/latest/reference/libtmux-session-options/
[snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-snapshot/
[subscriptionoverflow]: https://libtmux.org/en/ruby/latest/reference/libtmux-subscriptionoverflow/
[targetnotfounderror]: https://libtmux.org/en/ruby/latest/reference/libtmux-targetnotfounderror/
[tool-tmux_capabilities]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capabilities/
[tool-tmux_snapshot]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_snapshot/
[window]: https://libtmux.org/en/ruby/latest/reference/libtmux-window-1vfx/
[window-list_panes]: https://libtmux.org/en/ruby/latest/reference/libtmux-window-list_panes/
[window-split]: https://libtmux.org/en/ruby/latest/reference/libtmux-window-split/
[windowlink]: https://libtmux.org/en/ruby/latest/reference/libtmux-windowlink-tusj/
[workspace]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace/
