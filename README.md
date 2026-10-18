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
Ruby. Read server state into a [snapshot](https://libtmux.org/en/ruby/latest/reference/libtmux-snapshot/), then query
it with [`where`](https://libtmux.org/en/ruby/latest/reference/libtmux-selection-where/),
[`select`](https://libtmux.org/en/ruby/latest/reference/libtmux-selection-select/), and the rest of `Enumerable`.

[Quick start](#quick-start) · [Queries](#query-a-snapshot) · [Gems](#gems) ·
[Guide](docs/index.md) · [API reference](docs/reference/api.md) ·
[Recipes](docs/recipes.md) ·
[API on libtmux.org](https://libtmux.org/en/ruby/latest/reference/)

</div>

**Alpha.** APIs may change between releases. See the
[initial alpha notes](CHANGELOG.md) and [release guide](docs/releasing.md).

## Install

Install the core prerelease from RubyGems:

```console
$ gem install libtmux --pre
```

The [companion gems](#gems) install separately; use `--pre` for their alpha
versions too.

## Install from source

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

The gemspecs declare Ruby 3.3+ and the suite requires tmux 3.3a or newer;
unpatched 3.3 is below the minimum. A [server handle](https://libtmux.org/en/ruby/latest/reference/libtmux-server/)
checks the connected daemon's release, not the client's, and refuses an older daemon before any
requested command runs. The
[compatibility workflow](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml)
tests Ruby 3.3, 3.4, and 4.0 with tmux 3.3a–3.8 on Linux and macOS, runs the
suite against a pinned tmux master build, and checks that tmux 3.0a, 3.1c,
3.2a and 3.3 daemons are refused. Check the results for your revision before
relying on a particular combination.

## Quick start

Create a session and split its `logs` window.
[`Server.start`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-start/) owns a private tmux server and
closes it when the block exits. The snapshot remains readable afterward.

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

Run the [complete example](examples/quickstart.rb):

```console
$ mise exec -- bundle exec ruby examples/quickstart.rb
```

Output:

```text
main: %0
logs: %1, %2
```

Pane commands take argument arrays. To use an existing server, open an explicit
endpoint with
[`LibTmux::Server.open(socket_path: ...)`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-open/); closing
that binding leaves the daemon running. See [ownership and errors](docs/ownership-errors.md).

## Query a snapshot

Continue with the snapshot above. `where` accepts criteria as data; `select`
accepts a Ruby block. These queries make no tmux calls.

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

[`one`](https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one/) raises
[`NoMatchError`](https://libtmux.org/en/ruby/latest/reference/libtmux-nomatcherror/) or
[`MultipleMatchesError`](https://libtmux.org/en/ruby/latest/reference/libtmux-multiplematcheserror/) unless exactly
one record matches. [`one_or_nil`](https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one_or_nil/) returns
`nil` for no match and still rejects duplicates. Both errors live under
`LibTmux`.

Selections retain captured membership. Call
[`server.snapshot`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-snapshot/) again while the server is
open to read later changes. The [field catalog](docs/reference/fields.md)
lists query fields and wire names; the [list/filter recipe](examples/list_filter.rb)
also covers exact matches and queries after close.

## Gems

Start with `libtmux`. Add the companion for your caller:

| Gem | Require | Use it for |
| --- | --- | --- |
| [libtmux](gems/libtmux/README.md) | `libtmux` | Blocking scripts, snapshots, and control connections |
| [libtmux-async](gems/libtmux-async/README.md) | `libtmux/async` | Concurrent commands and bounded streams in Async tasks |
| [libtmux-mcp](gems/libtmux-mcp/README.md) | `libtmux/mcp` | An MCP server with explicit endpoints and tool policy |
| [libtmux-workspace](gems/libtmux-workspace/README.md) | `libtmux/workspace` | YAML/JSON workspace plans and a CLI to apply them |

Requiring a gem starts no tmux process, scheduler, or protocol server.
[Execution modes](docs/modes.md) explains blocking calls, Async tasks, and
control subscriptions. Tracked MCP captures, waits, and authored runs require
tmux 3.3a+ and native process identity; see the
[MCP guide](gems/libtmux-mcp/README.md).
Workspace client-switching semantics are in the
[workspace guide](gems/libtmux-workspace/README.md).

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
    pkg/libtmux-0.1.0.alpha.2.gem
```

Companion gems need their declared runtime dependencies too. The
[packaging check](.github/CONTRIBUTING.md#checks) verifies each gem in an
isolated installation and runs the recipes outside the checkout.

### [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux)

Blocking [server](https://libtmux.org/en/ruby/latest/reference/libtmux-server/), [session](https://libtmux.org/en/ruby/latest/reference/libtmux-session-nvps/),
[window](https://libtmux.org/en/ruby/latest/reference/libtmux-window-1vfx/) and [pane](https://libtmux.org/en/ruby/latest/reference/libtmux-pane-14z6/) handles,
immutable [snapshots](https://libtmux.org/en/ruby/latest/reference/libtmux-snapshot/), and
[control connections](https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection/). Require `libtmux`.

[API reference](https://libtmux.org/en/ruby/latest/reference/) ·
[Guides](https://libtmux.org/en/ruby/latest/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux)

```console
$ gem install libtmux --pre
```

The [quick start](#quick-start) and [snapshot queries](#query-a-snapshot)
above run against this gem.

### [libtmux-async](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-async)

Concurrent commands and bounded control streams inside an Async task that your
application owns. Require `libtmux/async`, then open a scope with
[`LibTmux::Async.open`](https://libtmux.org/en/ruby/latest/reference/libtmux-async-open/).

[API reference](https://libtmux.org/en/ruby/latest/reference/libtmux-async/) ·
[Guide](https://libtmux.org/en/ruby/latest/guides/async/) ·
[RubyGems](https://rubygems.org/gems/libtmux-async)

```console
$ gem install libtmux-async --pre
```

Capture every pane concurrently with
[`Scope#map`](https://libtmux.org/en/ruby/latest/reference/libtmux-async-scope-map/). `server` is an open
`LibTmux::Server`:

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

### [libtmux-mcp](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-mcp)

An MCP server over stdio for one tmux server, with an explicit tool policy.
Installs `libtmux-mcp`; require `libtmux/mcp` to embed it through
[`LibTmux::MCP::Application`](https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application/).

[API reference](https://libtmux.org/en/ruby/latest/mcp/reference/) ·
[Tools](https://libtmux.org/en/ruby/latest/mcp/tools/) ·
[Guides](https://libtmux.org/en/ruby/latest/mcp/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux-mcp)

```console
$ gem install libtmux-mcp --pre
```

The server borrows a tmux server that is already running. Start one on a
socket of its own:

```console
$ tmux -L agent new-session -d -s work
```

Add the server to Claude Code. Until you enable more tools, it serves
[`tmux_capabilities`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capabilities/)
and
[`tmux_snapshot`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_snapshot/):

```console
$ claude mcp add tmux -- libtmux-mcp --socket-name agent --endpoint dev
```

The [MCP README](gems/libtmux-mcp/README.md) covers other clients, every tool
and authored shell commands.

### [libtmux-workspace](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-workspace)

YAML or JSON workspaces, validated, planned offline and applied to an open
server. Installs `libtmux-workspace`; require `libtmux/workspace` to use it
from Ruby through
[`LibTmux::Workspace`](https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace/).

[API reference](https://libtmux.org/en/ruby/latest/workspace/reference/) ·
[Command reference](https://libtmux.org/en/ruby/latest/workspace/cli/) ·
[Guides](https://libtmux.org/en/ruby/latest/workspace/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux-workspace)

```console
$ gem install libtmux-workspace --pre
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
running server and lists every option.

Tracked MCP captures, waits, and authored runs require tmux 3.3a+ and native
process identity; see the [MCP guide](gems/libtmux-mcp/README.md). Workspace
client-switching semantics are in the
[workspace guide](gems/libtmux-workspace/README.md).

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
    pkg/libtmux-0.1.0.alpha.2.gem
```

Companion gems need their declared runtime dependencies too. The
[packaging check](.github/CONTRIBUTING.md#checks) verifies each gem in an
isolated installation and runs the recipes outside the checkout.

## More examples and reference

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
[MIT license](LICENSE).

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
