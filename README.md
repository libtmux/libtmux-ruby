# libtmux for Ruby

Create tmux sessions, split windows, send input, and capture pane output from
Ruby. Read server state into a snapshot, then query it with `where`, `select`,
and the rest of `Enumerable`.

[Quick start](#quick-start) · [Queries](#query-a-snapshot) · [Gems](#gems) ·
[Guide](docs/index.md) · [API reference](docs/reference/api.md) ·
[Recipes](docs/recipes.md)

**Unreleased.** Build and use the gems from this checkout.

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

The gemspecs declare Ruby 3.3+. The
[compatibility workflow](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml)
tests Ruby 3.3, 3.4, and 4.0 with tmux 3.2a–3.7c on Linux and macOS. Check the
results for your revision before relying on a particular combination.

## Quick start

Create a session and split its `logs` window. `Server.start` owns a private
tmux server and closes it when the block exits. The snapshot remains readable
afterward.

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
endpoint with `LibTmux::Server.open(socket_path: ...)`; closing that binding
leaves the daemon running. See [ownership and errors](docs/ownership-errors.md).

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

`one` raises `NoMatchError` or `MultipleMatchesError` unless exactly one record
matches. `one_or_nil` returns `nil` for no match and still rejects duplicates.
Both errors live under `LibTmux`.

Selections retain captured membership. Call `server.snapshot` again while the
server is open to read later changes. The [field catalog](docs/reference/fields.md)
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
tmux 3.3+ and native process identity; see the [MCP guide](gems/libtmux-mcp/README.md).
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
    pkg/libtmux-0.1.0.alpha.1.gem
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
