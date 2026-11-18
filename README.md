<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Ruby">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Ruby

Create tmux sessions, split windows, send input, and capture pane output from
Ruby. Read server state into a [snapshot][snapshot], then query it with
[`where`][selection-where], [`select`][selection-select], and the rest of
`Enumerable`.

[Quick start](#quick-start) · [Find things](#find-things-in-a-snapshot) ·
[Packages](#packages) · [Guide](docs/index.md) ·
[API reference](docs/reference/api.md) · [Recipes](docs/recipes.md) ·
[API on libtmux.org](https://libtmux.org/en/ruby/latest/reference/)

[![compatibility](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml/badge.svg)](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml)
[![libtmux](https://img.shields.io/gem/v/libtmux?label=libtmux)](https://rubygems.org/gems/libtmux)
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/ruby/)
[![license](https://img.shields.io/badge/license-MIT-blue)](https://github.com/libtmux/libtmux-ruby/blob/master/LICENSE)

</div>

It suits scripts, tests that need a real tmux, and tools that drive a terminal
program. An [MCP server][mcp-application], an Async adapter and a workspace
loader ship beside the core: see [Packages](#packages).

**Contents** — [Quick start](#quick-start) ·
[Drive a pane](#drive-a-pane) ·
[Find things](#find-things-in-a-snapshot) ·
[Several commands](#run-several-commands-in-order) ·
[Watch tmux](#watch-tmux-change) ·
[Your own server](#use-the-tmux-server-you-already-run) ·
[Packages](#packages) · [Build from source](#build-from-source) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status) ·
[Documentation](#documentation)

## Quick start

Install the core gem. It needs Ruby 3.3 or newer and tmux 3.3a or newer on
`PATH`:

```console
$ gem install libtmux
```

This program creates a session, adds a window, splits it, and prints each
window with its panes:

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

Save it as `quickstart.rb` and run it:

```console
$ ruby quickstart.rb
```

It prints:

```text
main: %0
logs: %1, %2
```

[`Server.start`][server-start] gives the program a tmux server of its own, on
its own socket with an empty configuration, and closes it when the block exits.
It never touches a tmux you already use. Pane commands take argument arrays.

## Drive a pane

### [`Pane#split`][pane-split]: split a pane, type into it, resize it

[`send_text`][pane-send_text] types literal text, [`send_keys`][pane-send_keys]
sends key names such as `Enter`, and [`capture`][pane-capture] reads the screen.
[`Pane#resize`][pane-resize] and [`Window#resize`][window-resize] set sizes in
cells:

<!-- example: api_split_resize/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  created = server.new_session(name: "work", command: ["/bin/sh"], receipt: true)
  pane = created.pane
  side = pane.split(direction: :horizontal, size: "40%", command: ["/bin/cat"])

  pane.send_text("echo ready")
  pane.send_keys("Enter")
  line = nil
  50.times do
    line = pane.capture.stdout.lines(chomp: true).find { |text| text == "ready" }
    break if line
    sleep 0.1
  end
  puts "captured: #{line}"

  created.window.resize(width: 100, height: 30)
  side.resize(width: 20)
  puts "side pane: #{side.snapshot.width} columns"
end
```
<!-- /example -->

It prints `captured: ready` and `side pane: 20 columns`.
[`Entity#kill`][entity-kill] removes a pane, window or session, and
[`Server#kill`][server-kill] stops a daemon. More:
[pane input and capture](docs/reference/behavior.md#pane-input-and-capture).

## Find things in a snapshot

### [`Server#snapshot`][server-snapshot]: one read, many queries

[`where`][selection-where] takes criteria as data and
[`select`][selection-select] takes a Ruby block. Both filter the snapshot
locally and make no tmux calls:

<!-- example: quickstart/queries -->
```ruby
require "libtmux"

snapshot = LibTmux::Server.start do |server|
  session = server.new_session(name: "work", window_name: "main", command: ["/bin/cat"])
  window = session.new_window(name: "logs", command: ["/bin/cat"])
  window.split(direction: :horizontal, size: "40%", command: ["/bin/cat"])

  server.snapshot
end

panes = snapshot.panes
active_ids = panes.where(active: true).map(&:id)
wide_panes = panes.select { |pane| pane.width >= 40 }
panes_by_window = panes.group_by { |pane| pane.window.name }

logs = snapshot.windows.one(name: "logs")
missing = snapshot.windows.one_or_nil(name: "missing")

puts "active: #{active_ids.join(', ')}"
puts "wide: #{wide_panes.map(&:id).join(', ')}"
puts "logs panes: #{logs.panes.length}"
puts "missing: #{missing.inspect}"
```
<!-- /example -->

It prints:

```text
active: %0, %1
wide: %0, %1
logs panes: 2
missing: nil
```

- [`one`][selection-one] raises [`NoMatchError`][nomatcherror] or
  [`MultipleMatchesError`][multiplematcheserror] unless exactly one record
  matches. [`one_or_nil`][selection-one_or_nil] returns `nil` for none.
- A selection keeps the membership it captured. Call
  [`server.snapshot`][server-snapshot] again to see later changes.

More: the [field catalog][doc-fields] and the
[list and filter recipe](examples/list_filter.rb).

### [`Server#explain_panes`][server-explain_panes]: what runs in tmux, what runs in Ruby

[`explain_panes`][server-explain_panes] returns the plan for a pane query and
sends nothing to tmux. [`search_panes`][server-search_panes] runs it. Today tmux
returns the whole server and Ruby applies every criterion:

<!-- example: api_explain_panes/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  server.new_session(name: "work", command: ["/bin/cat"])
  criteria = {active: true}
  plan = server.explain_panes(where: criteria)
  puts "tmux reads: #{plan.fetch(:capture)}"
  puts "tmux filters: #{plan.fetch(:pushed) || 'nothing'}"
  puts "Ruby filters: #{plan.fetch(:residual).fetch('where').keys.join(', ')}"
  puts "matching panes: #{server.search_panes(where: criteria).length}"
end
```
<!-- /example -->

It prints:

```text
tmux reads: full_graph
tmux filters: nothing
Ruby filters: active
matching panes: 1
```

More: [execution modes][doc-modes].

### [`Window#snapshot`][window-snapshot]: read one object again

A record is what tmux said when it was read. Ruby has no `refresh` that
updates a record in place, as Python libtmux's `.refresh()` does: read the
object again.

[`Window#snapshot`][window-snapshot] returns a new record and leaves the one you
hold as it was. [`Session#snapshot`][session-snapshot] and
[`Pane#snapshot`][pane-snapshot] do the same:

<!-- example: refresh/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  session = server.new_session(name: "work", window_name: "editor", command: ["/bin/cat"])
  window = session.list_windows.fetch(0)

  held = window.snapshot
  window.rename("build")

  puts held.name
  puts window.snapshot.name
end
```
<!-- /example -->

It prints:

```text
editor
build
```

Each call reads the whole server, as [`server.snapshot`][server-snapshot] does,
and returns the one record you asked for.

## Run several commands in order

### [`Server#run_group`][server-run_group]: several commands through one client

A group sends several tmux commands, in order, through one client. The
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
runs. More: the [group recipe](docs/recipes.md#failure-inside-a-group).

## Watch tmux change

### [`Server#open_control`][server-open_control]: events as they happen

A [`ControlConnection`][controlconnection] runs a command with
[`exchange`][controlconnection-exchange] and streams what tmux reports through
[`subscribe`][controlconnection-subscribe]. The subscription's
[`next`][controlsubscription-next] waits for the next
[`ControlEvent`][controlevent]. It needs tmux 3.7 or newer:

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

More: the [control overflow recipe](docs/recipes.md#control-overflow).

## Check what the daemon supports

### [`Server#capabilities`][server-capabilities]: feature requirements and decisions

Read the connected daemon's feature report. Use its support query before
choosing an optional operation, or inspect the required release and refusal.

<!-- example: api_capabilities/main -->
```ruby
require "libtmux"

LibTmux::Server.start do |server|
  report = server.capabilities
  feature = report.feature("layout-json")
  puts "JSON layouts require tmux #{feature.since}"
  puts "Refusal: #{feature.error}"
end
```
<!-- /example -->

```text
JSON layouts require tmux 3.8
Refusal: LibTmux::UnsupportedFeatureError
```

More: [Support queries, workarounds and snapshot limits][behavior-capabilities].

## Use the tmux server you already run

### [`Server.new`][server-new]: borrow a daemon

[`Server.open`][server-open] and [`Server.new`][server-new] bind an endpoint
that already exists, such as `Server.open(socket_path: ...)`. Closing the
binding leaves the daemon running. The outer [`Server.start`][server-start]
block here only supplies a daemon to borrow:

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

More: [ownership and errors][doc-ownership].

## Packages

Start with `libtmux`. Add the companion for your caller:

| Gem | Require | Use it for |
| --- | --- | --- |
| [libtmux](gems/libtmux/README.md) | `libtmux` | Blocking scripts, snapshots, and control connections |
| [libtmux-async](gems/libtmux-async/README.md) | `libtmux/async` | Concurrent commands and bounded streams in Async tasks [![libtmux-async](https://img.shields.io/gem/v/libtmux-async?label=libtmux-async)](https://rubygems.org/gems/libtmux-async) |
| [libtmux-mcp](gems/libtmux-mcp/README.md) | `libtmux/mcp` | An MCP server with explicit endpoints and tool policy [![libtmux-mcp](https://img.shields.io/gem/v/libtmux-mcp?label=libtmux-mcp)](https://rubygems.org/gems/libtmux-mcp) |
| [libtmux-workspace](gems/libtmux-workspace/README.md) | `libtmux/workspace` | YAML/JSON workspace plans and a CLI to apply them [![libtmux-workspace](https://img.shields.io/gem/v/libtmux-workspace?label=libtmux-workspace)](https://rubygems.org/gems/libtmux-workspace) |

Requiring a gem starts no tmux process, scheduler, or protocol server.
[Execution modes][doc-modes] compares blocking calls, Async tasks, and control
subscriptions.

### [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux): the core

Blocking [server][server], [session][session], [window][window] and
[pane][pane] handles, immutable [snapshots][snapshot], and
[control connections][controlconnection]. Require `libtmux`.

[API reference](https://libtmux.org/en/ruby/latest/reference/) ·
[Guides](https://libtmux.org/en/ruby/latest/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux)

```console
$ gem install libtmux
```

More tasks, in the [core README](gems/libtmux/README.md):

- [Type into a pane and read it back](gems/libtmux/README.md#type-into-a-pane-and-read-it-back)
- [Wait, time out, and cancel](gems/libtmux/README.md#wait-time-out-and-cancel)
- [Read and set options and hooks](gems/libtmux/README.md#read-and-set-options-and-hooks)
- [Link a window into several sessions](gems/libtmux/README.md#link-a-window-into-several-sessions)

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

Capture every pane concurrently with [`Scope#map`][async-scope-map]:

<!-- example: api_async_scope/main -->
```ruby
require "libtmux"
require "libtmux/async"

LibTmux::Server.start do |server|
  server.new_session(name: "work", command: ["/bin/cat"])
  server.new_session(name: "logs", command: ["/bin/cat"])
  Async do |parent|
    LibTmux::Async.open(parent: parent, server: server) do |scope|
      refs = scope.server.list_panes.map(&:ref)
      screens = scope.map(refs, concurrency: 2) { |ref| scope.server.pane(ref).capture }
      puts "captured panes: #{screens.length}"
      puts "all succeeded: #{screens.all?(&:success?)}"
    end
  end.wait
end
```
<!-- /example -->

It prints:

```text
captured panes: 2
all succeeded: true
```

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

Add the server to Claude Code. `--start-session work` starts a tmux server on
the socket `agent` when none answers there, with a session named `work`, and
stops it when the server exits. Until you enable more tools, the server serves
[`tmux_capabilities`][tool-tmux_capabilities] and
[`tmux_snapshot`][tool-tmux_snapshot]:

```console
$ claude mcp add tmux -- libtmux-mcp \
    --socket-name agent \
    --start-session work \
    --endpoint dev
```

More: the [MCP README](gems/libtmux-mcp/README.md) covers other clients, every
tool and authored shell commands.

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

More: the [workspace README](gems/libtmux-workspace/README.md) loads it into a
running server and lists every option.

## Build from source

From a checkout, install the Ruby pinned in [.tool-versions](.tool-versions),
then the development bundle:

```console
$ mise install
```

```console
$ mise exec -- bundle config set --local path vendor/bundle
```

```console
$ mise exec -- bundle install
```

To use the core outside the checkout, build the artifacts:

```console
$ mise exec -- bundle exec rake build
```

Install the core into the Ruby that will run your application. Its runtime
dependencies must already be installed:

```console
$ gem install \
    --local \
    --no-document \
    pkg/libtmux-0.1.2.gem
```

Companion gems need their runtime dependencies too. See
[Contributing](.github/CONTRIBUTING.md#checks) for the checks.

## What it leaves out

- **Live objects.** A [snapshot][snapshot] record is what tmux said when you
  read it, and a selection keeps the membership it captured. Read again to see
  a change.
- **A terminal emulator.** [`Pane#capture`][pane-capture] returns what tmux's
  `capture-pane` prints for the pane.
- **A server it starts unasked.** [`Server.new`][server-new] and
  [`Server.open`][server-open] bind a running server; only
  [`Server.start`][server-start] starts one. With no socket named,
  [`Endpoint.new`][endpoint-new] picks the socket tmux would, so a program run
  inside tmux reaches that tmux. See [Endpoints][doc-endpoints].
- **Whole-program typing.** RBS declarations ship with each gem. See the
  [public methods][doc-api].
- **Throughput claims.** The [benchmarks][doc-benchmark] list their workloads
  and limits.

## Support and status

- **Unstable API.** Releases are numbered `0.1.N`, and any release may change
  or remove exported identifiers. Pin an exact version. See the
  [changelog](CHANGELOG.md), which links each gem's own.
- **Ruby 3.3 or newer** and **tmux 3.3a or newer.** A [server handle][server]
  refuses an older daemon before it runs a command. Release candidates are not
  supported. See [Release candidates][rc-policy].
- **Control connections need tmux 3.7 or newer.** On an older daemon
  `open_control` raises `UnsupportedFeatureError`, and `Server#supports_control?`
  returns false. The [optional-feature table][doc-optional-features] and
  [`capabilities.json`][capabilities-json] list the other releases.
- **Linux, including WSL, and macOS.** CI runs on Linux; macOS is best effort.
  See the [compatibility workflow][compat] and the
  [CI matrix](.github/CONTRIBUTING.md#running-ci-against-any-tmux).

## Documentation

- [Send text and capture output](examples/layout_io.rb): split panes, wait for
  output events, and round-trip binary buffers.
- [Work with linked windows](examples/window_links.rb): address one window at
  several session indexes.
- [Capture concurrently](examples/async_cancel.rb): read panes while another
  request waits, then cancel it.
- [Load a workspace](examples/workspace_apply.rb): parse a configuration, plan,
  and apply it.
- [All recipes](docs/recipes.md): cancellation, control streams, command groups,
  and MCP.
- [API reference](docs/reference/api.md): public methods, source links, and
  behavioral contracts.
- [Benchmarks](docs/benchmark.md): workloads, measurements, and their limits.

See [Contributing](.github/CONTRIBUTING.md) for setup and checks.

## AI policy

Use these packages with AI tools as you like. When contributing, check what you
submit and wait for a maintainer's invitation before preparing a pull request.
See the [AI policy](https://libtmux.org/en/meta/ai-policy/), also kept as
[AI_POLICY.md](https://github.com/libtmux/.github/blob/HEAD/AI_POLICY.md).

## Attribution

Please use the following BibTeX template to cite libtmux-ruby in scientific discourse:

```bibtex
@misc{libtmux-ruby,
   author = {Tony Narlock},
   year = {2026},
   note = {https://libtmux.org/en/ruby/},
   title = {libtmux-ruby: Ruby wrapper for tmux}
}
```

## License

MIT. See [LICENSE](LICENSE).

[async-open]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-open/
[async-scope-map]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-scope-map/
[capabilities-json]: capabilities.json
[compat]: https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml
[controlconnection]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection/
[controlconnection-exchange]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection-exchange/
[controlconnection-subscribe]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection-subscribe/
[controlevent]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlevent/
[controlsubscription-next]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlsubscription-next/
[doc-api]: docs/reference/api.md
[doc-benchmark]: docs/benchmark.md
[doc-endpoints]: docs/reference/behavior.md#endpoints
[doc-fields]: docs/reference/fields.md
[doc-modes]: docs/modes.md
[doc-optional-features]: docs/reference/behavior.md#optional-tmux-features
[doc-ownership]: docs/ownership-errors.md
[endpoint-new]: https://libtmux.org/en/ruby/latest/reference/libtmux-endpoint-new/
[entity-kill]: https://libtmux.org/en/ruby/latest/reference/libtmux-entity-kill/
[groupresult]: https://libtmux.org/en/ruby/latest/reference/libtmux-groupresult/
[mcp-application]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application/
[multiplematcheserror]: https://libtmux.org/en/ruby/latest/reference/libtmux-multiplematcheserror/
[nomatcherror]: https://libtmux.org/en/ruby/latest/reference/libtmux-nomatcherror/
[pane]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-14z6/
[pane-capture]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-capture/
[pane-resize]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-resize/
[pane-send_keys]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-send_keys/
[pane-send_text]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-send_text/
[pane-snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-snapshot/
[pane-split]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-split/
[rc-policy]: https://libtmux.org/en/tmux/guides/tmux-support/#release-candidates
[selection-one]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one/
[selection-one_or_nil]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one_or_nil/
[selection-select]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-select/
[selection-where]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-where/
[server]: https://libtmux.org/en/ruby/latest/reference/libtmux-server/
[server-explain_panes]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-explain_panes/
[server-kill]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-kill/
[server-new]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-new/
[server-open]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-open/
[server-open_control]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-open_control/
[server-run_group]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-run_group/
[server-search_panes]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-search_panes/
[server-snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-snapshot/
[server-start]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-start/
[session]: https://libtmux.org/en/ruby/latest/reference/libtmux-session-nvps/
[session-snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-session-snapshot/
[snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-snapshot/
[tool-tmux_capabilities]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capabilities/
[tool-tmux_snapshot]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_snapshot/
[window]: https://libtmux.org/en/ruby/latest/reference/libtmux-window-1vfx/
[window-resize]: https://libtmux.org/en/ruby/latest/reference/libtmux-window-resize/
[window-snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-window-snapshot/
[workspace]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace/

[server-capabilities]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-capabilities/
[behavior-capabilities]: docs/reference/behavior.md#daemon-capabilities
