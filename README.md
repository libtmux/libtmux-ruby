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

</div>

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelog marks each break. Pin an exact version to avoid one.
See the [changelog](CHANGELOG.md) and [release guide](docs/releasing.md).

It suits scripts, tests that need a real tmux, and tools that drive a terminal
program. An [MCP server][mcp-application], an Async adapter and a workspace
loader ship beside the core, under [Packages](#packages).

**Contents** — [Quick start](#quick-start) ·
[Find things](#find-things-in-a-snapshot) ·
[Your own server](#use-the-tmux-server-you-already-run) ·
[Packages](#packages) · [Build from source](#build-from-source) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status) ·
[Documentation](#documentation)

## Quick start

Install the core gem from RubyGems. It needs Ruby 3.3 or newer and tmux
3.3a or newer on `PATH`:

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

From a checkout, run the [complete example](examples/quickstart.rb):

```console
$ mise exec -- bundle exec ruby examples/quickstart.rb
```

It prints:

```text
main: %0
logs: %1, %2
```

Pane commands take argument arrays. [`Server.start`][server-start] gives its
tmux server a socket and an empty configuration of its own, so it never
touches a tmux you already use.

## Find things in a snapshot

### [`Server#snapshot`][server-snapshot]: one read, many queries

Continue with the snapshot above. [`where`][selection-where] accepts criteria
as data, and [`select`][selection-select] accepts a Ruby block. These queries
make no tmux calls:

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

[`one`][selection-one] raises [`NoMatchError`][nomatcherror] or
[`MultipleMatchesError`][multiplematcheserror] unless exactly one record
matches. [`one_or_nil`][selection-one_or_nil] returns `nil` for no match and
still rejects duplicates. Both errors live under `LibTmux`.

A selection keeps the membership it captured. Call
[`server.snapshot`][server-snapshot] again while the server is open to read
later changes.

The [field catalog][doc-fields] lists query fields and wire names, and the
[list/filter recipe](examples/list_filter.rb) covers exact matches and queries
after close.

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

See [ownership and errors][doc-ownership] for what close and failure mean.

## Packages

Start with `libtmux`. Add the companion for your caller:

| Gem | Require | Use it for |
| --- | --- | --- |
| [libtmux](gems/libtmux/README.md) | `libtmux` | Blocking scripts, snapshots, and control connections |
| [libtmux-async](gems/libtmux-async/README.md) | `libtmux/async` | Concurrent commands and bounded streams in Async tasks |
| [libtmux-mcp](gems/libtmux-mcp/README.md) | `libtmux/mcp` | An MCP server with explicit endpoints and tool policy |
| [libtmux-workspace](gems/libtmux-workspace/README.md) | `libtmux/workspace` | YAML/JSON workspace plans and a CLI to apply them |

Requiring a gem starts no tmux process, scheduler, or protocol server. The
companion gems install separately. [Execution modes][doc-modes] explains
blocking calls, Async tasks, and control subscriptions.

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

The [quick start](#quick-start) and
[snapshot queries](#find-things-in-a-snapshot) above run against this gem.

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

The [MCP README](gems/libtmux-mcp/README.md) covers other clients, every tool
and authored shell commands. Tracked captures, waits and authored runs need
tmux 3.3a or newer and native process identity.

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

The [workspace README](gems/libtmux-workspace/README.md) loads it into a
running server and lists every option, including how `--switch` moves a
client.

## Build from source

Use the Ruby pinned in [.tool-versions](.tool-versions) and have `tmux` on your
`PATH`. From this checkout, install the development bundle:

```console
$ mise install
```

```console
$ mise exec -- bundle config set --local path vendor/bundle
```

```console
$ mise exec -- bundle install
```

To use the core outside this checkout, build the artifacts:

```console
$ mise exec -- bundle exec rake build
```

Install into the Ruby environment that will run your application. The core's
runtime dependencies must already be installed for this local-only command:

```console
$ gem install \
    --local \
    --no-document \
    pkg/libtmux-0.1.0.gem
```

Companion gems need their declared runtime dependencies too. The
[packaging check](.github/CONTRIBUTING.md#checks) verifies each gem in an
isolated installation and runs the recipes outside the checkout.

## What it leaves out

- **Live objects.** A [snapshot][snapshot] record is what tmux said when you
  read it, and a selection keeps the membership it captured. Read again to see
  a change.
- **A terminal emulator.** [`Pane#capture`][pane-capture] returns what tmux's
  `capture-pane` prints for the pane.
- **An implied server.** [`Endpoint.new`][endpoint-new] needs an explicit
  socket, and no API in the recipes uses the default server.
- **Whole-program typing.** RBS declarations ship with each gem, and selected
  installed calls are checked. See the [public methods][doc-api].
- **Throughput claims.** The [benchmarks][doc-benchmark] list their workloads,
  measurements and limits.

## Support and status

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelog marks each break. Pin an exact version to avoid one.

- **Ruby 3.3 or newer** and **tmux 3.3a or newer.** Unpatched 3.3 is below the
  minimum. A [server handle][server] checks the connected daemon's release, not
  the client's, and refuses an older daemon before any requested command runs.
- **Linux, including WSL, and macOS.** The [compatibility workflow][compat]
  runs Ruby 3.3, 3.4 and 4.0 with tmux 3.3a through 3.8 on Ubuntu 24.04.
  macOS is supported on a best-effort basis, and CI coverage for it is highly
  limited.
- **Control connections need tmux 3.7 or newer.** On an older daemon
  `open_control` raises `UnsupportedFeatureError` before a client attaches,
  and `Server#supports_control?` returns false. Other optional features carry
  their own releases in the [optional-feature table][doc-optional-features];
  [`capabilities.json`][capabilities-json] holds the same records for tools.
- **tmux master and old daemons.** On Ubuntu the workflow also runs the suite
  against a pinned tmux master, and checks that tmux 3.0a, 3.1c, 3.2a and 3.3
  daemons are refused.
- **Per-revision results.** Check the workflow's results for your revision
  before relying on one combination.

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
  behavioral contracts. RBS declarations ship with each gem; selected installed
  calls are checked, without a whole-program typing guarantee.
- [Benchmarks](docs/benchmark.md): workloads, measurements, and their limits.

See [Contributing](.github/CONTRIBUTING.md) for setup and checks.

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
[compat]: https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml
[controlconnection]: https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection/
[doc-api]: docs/reference/api.md
[doc-benchmark]: docs/benchmark.md
[doc-fields]: docs/reference/fields.md
[doc-modes]: docs/modes.md
[doc-optional-features]: docs/reference/behavior.md#optional-tmux-features
[capabilities-json]: capabilities.json
[doc-ownership]: docs/ownership-errors.md
[endpoint-new]: https://libtmux.org/en/ruby/latest/reference/libtmux-endpoint-new/
[mcp-application]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application/
[multiplematcheserror]: https://libtmux.org/en/ruby/latest/reference/libtmux-multiplematcheserror/
[nomatcherror]: https://libtmux.org/en/ruby/latest/reference/libtmux-nomatcherror/
[pane]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-14z6/
[pane-capture]: https://libtmux.org/en/ruby/latest/reference/libtmux-pane-capture/
[selection-one]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one/
[selection-one_or_nil]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one_or_nil/
[selection-select]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-select/
[selection-where]: https://libtmux.org/en/ruby/latest/reference/libtmux-selection-where/
[server]: https://libtmux.org/en/ruby/latest/reference/libtmux-server/
[server-new]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-new/
[server-open]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-open/
[server-snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-snapshot/
[server-start]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-start/
[session]: https://libtmux.org/en/ruby/latest/reference/libtmux-session-nvps/
[snapshot]: https://libtmux.org/en/ruby/latest/reference/libtmux-snapshot/
[tool-tmux_capabilities]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capabilities/
[tool-tmux_snapshot]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_snapshot/
[window]: https://libtmux.org/en/ruby/latest/reference/libtmux-window-1vfx/
[workspace]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace/
