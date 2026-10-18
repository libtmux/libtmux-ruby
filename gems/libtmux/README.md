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

Ruby tmux orchestration core. [`Server.open`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-open/) borrows an
existing explicit endpoint. Closing it retires owned clients and preserves
the daemon; [`kill`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-kill/) explicitly terminates the daemon.
[`Server.start`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-start/) creates a
private owned foreground daemon whose lifetime ends with its server handle.
Owned startup uses Linux and Darwin readiness backends. The
[compatibility workflow](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml)
retains exact per-revision platform and version results.

[API reference](https://libtmux.org/en/ruby/latest/reference/) ·
[Guides](https://libtmux.org/en/ruby/latest/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux)

</div>

Part of [libtmux for Ruby](https://github.com/libtmux/libtmux-ruby#readme).
This gem is the core; the [gems below](#gems) build on it.

**Contents** — [Install](#install) · [Quick start](#quick-start) ·
[Gems](#gems) · [Behavior](#behavior): [handles](#handles-and-refs) ·
[linked windows](#linked-windows) · [creation](#arguments-and-creation) ·
[deadlines](#deadlines-and-cancellation) · [options](#options-and-hooks) ·
[capture](#capture-buffers-and-clients) · [control](#control-connections) ·
[coverage](#coverage-and-verification)

Requires tmux 3.3a or newer; unpatched 3.3 is below the minimum. A server
handle checks the connected daemon's release before any command is
dispatched, and refuses an older daemon even when its client is newer.

## Install

Install the alpha, then require `libtmux`. Imports do not start tmux, a
scheduler or an MCP server. See the repository's
[contribution guide](../../.github/CONTRIBUTING.md) for local build and
verification commands.

```console
$ gem install libtmux --pre
```

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

Output:

```text
main: %0
logs: %1, %2
```

Query the snapshot with [`where`](https://libtmux.org/en/ruby/latest/reference/libtmux-selection-where/), [`select`](https://libtmux.org/en/ruby/latest/reference/libtmux-selection-select/),
[`one`](https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one/) and [`one_or_nil`](https://libtmux.org/en/ruby/latest/reference/libtmux-selection-one_or_nil/). The
[repository README](https://github.com/libtmux/libtmux-ruby#query-a-snapshot)
shows the queries, and the [list/filter recipe](../../examples/list_filter.rb)
covers exact matches and queries after close.

## Gems

Start with `libtmux`. Add the companion for your caller:

| Gem | Require | Use it for |
| --- | --- | --- |
| [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux) | `libtmux` | Blocking scripts, snapshots, and control connections |
| [libtmux-async](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-async) | `libtmux/async` | Concurrent commands and bounded streams in Async tasks |
| [libtmux-mcp](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-mcp) | `libtmux/mcp` | An MCP server with explicit endpoints and tool policy |
| [libtmux-workspace](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-workspace) | `libtmux/workspace` | YAML/JSON workspace plans and a CLI to apply them |

### [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux)

This gem: blocking [server](https://libtmux.org/en/ruby/latest/reference/libtmux-server/), [session](https://libtmux.org/en/ruby/latest/reference/libtmux-session-nvps/),
[window](https://libtmux.org/en/ruby/latest/reference/libtmux-window-1vfx/) and [pane](https://libtmux.org/en/ruby/latest/reference/libtmux-pane-14z6/) handles,
immutable [snapshots](https://libtmux.org/en/ruby/latest/reference/libtmux-snapshot/), and
[control connections](https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection/). The quick start above
runs against it.

[API reference](https://libtmux.org/en/ruby/latest/reference/) ·
[Guides](https://libtmux.org/en/ruby/latest/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux)

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

The [MCP README](../libtmux-mcp/README.md) covers other clients, every tool
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

The [workspace README](../libtmux-workspace/README.md) loads it into a running
server and lists every option.

## Behavior

### Handles and refs

Handles carry immutable refs bound to one open server binding. IDs and refs
are local readers; `list_*`, [`snapshot`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-snapshot/) and command methods perform explicit
I/O. Global windows represent unique entities. [`WindowLink`](https://libtmux.org/en/ruby/latest/reference/libtmux-windowlink-tusj/) retains a session,
index and window ID so repeated links stay distinct.

### Linked windows

Link selection, unlinking, movement, swapping and display check the complete
link identity in the same tmux queue turn as their operation. Configured
command aliases are avoided using unshadowed builtin spellings. Hook waits
before dispatch cannot turn a stale link into its replacement. Concurrent
rewriting of command aliases is outside this guarantee; applications must
coordinate configuration changes.

### Arguments and creation

Typed arguments preserve literal semicolons and distinguish pane text from
key names. Pane commands take executable argument arrays. Hook commands,
display formats, pipe shell commands and [`source_file`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-source_file/) configuration are
explicit executable inputs. [`Server.run`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-run/) remains the raw tmux escape hatch,
including daemon aliases, separators and format semantics.

Creation accepts `cwd:` and a String-to-String `environment:` map. Directories
resolve from the Ruby caller and are checked before dispatch; concurrent
filesystem changes can still trigger tmux's directory fallback. Creation
returns tmux-assigned IDs after dispatch, without claiming program readiness
or a successful program exit. [`new_session(window_name:)`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-new_session/) names the initial
window; its index can be moved explicitly after creation. [`new_window(index:)`](https://libtmux.org/en/ruby/latest/reference/libtmux-session-new_window/)
refuses an occupied slot. [`Pane#split`](https://libtmux.org/en/ruby/latest/reference/libtmux-pane-split/) targets that exact pane, with `size:` as
cells or a percentage string. Windows and splits retain focus unless
`focus: true` is requested.

### Deadlines and cancellation

Typed operations accept `timeout:` and `cancel:`. Composed link and copy operations
share one deadline across their preflights and final dispatch. Copy-mode
exit uses `cancel_mode: true`; `cancel:` accepts [`LibTmux::Cancellation.new`](https://libtmux.org/en/ruby/latest/reference/libtmux-cancellation-new/).
Call the token's [`cancel`](https://libtmux.org/en/ruby/latest/reference/libtmux-cancellation-cancel/) from another thread to wake a blocked request, join
its caller, then [`close`](https://libtmux.org/en/ruby/latest/reference/libtmux-cancellation-close/) the token. See the [plain-Ruby cancellation recipe](../../examples/cancel.rb)
and [ownership contract](../../docs/ownership-errors.md).

### Options and hooks

[`Options`](https://libtmux.org/en/ruby/latest/reference/libtmux-options/) retains raw bytes, inheritance and sparse array indexes;
[`OptionValue#as`](https://libtmux.org/en/ruby/latest/reference/libtmux-optionvalue-as/) requests a strict conversion. Hook values remain tmux command
strings. The stable tmux option listing uses its escaped representation,
including octal bytes; it does not split raw values on line breaks. Option
names containing whitespace are currently rejected. Inherited hook listing
is not implemented and raises explicitly.

Indexed [`get`](https://libtmux.org/en/ruby/latest/reference/libtmux-options-get/) acquires the array and selects locally, so a missing index raises
[`NoMatchError`](https://libtmux.org/en/ruby/latest/reference/libtmux-nomatcherror/) while a present empty value remains present. Reading an array
without an index raises [`MultipleMatchesError`](https://libtmux.org/en/ruby/latest/reference/libtmux-multiplematcheserror/) when it has several entries.
Append follows tmux's lowest-free-index rule; indexed hooks execute in index
order. Empty arrays remain distinct from empty String values.

### Capture, buffers and clients

Binary buffers and command results preserve trailing newlines. [Capture](https://libtmux.org/en/ruby/latest/reference/libtmux-pane-capture/) can
join wrapped lines, include attribute escapes, escape nonprintable bytes,
preserve trailing spaces and trim unused trailing cells. `mode_screen: true`
reads the mode's backing screen (the copy-mode snapshot, without its UI),
`alternate: true` reads tmux's saved screen and raises when absent (while an
application occupies the alternate screen, this is the saved main screen),
and `pending: true` reads an incomplete escape sequence. These three selectors
are mutually exclusive. Mode-screen and trailing-cell flags are checked
against advertised command usage; unsupported requests raise explicitly.
Copy-mode flags are checked against the connected daemon's advertised command
usage. Client discovery returns observations. [`Server#attach`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-attach/) uses an explicit
caller-owned TTY and terminal type, waits for its owned client to exit, and
restores the terminal mode. [`Server#switch_client(client:, session:)`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-switch_client/) switches
an explicit current native client selector to an exact bound session, keeping
the session environment. A missing selector fails without fallback. This
operation does not turn a client observation into an incarnation-safe
reference; a reconnect matching the selector is eligible at dispatch.

### Control connections

Control connections expose bounded event subscriptions and raw guarded replies.
[`pause_output(pane_id:)`](https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection-pause_output/) and [`resume_output(pane_id:)`](https://libtmux.org/en/ruby/latest/reference/libtmux-controlconnection-resume_output/) return [`GuardedReply`](https://libtmux.org/en/ruby/latest/reference/libtmux-guardedreply/);
they do not establish that an action took effect. Their gap events identify
`:pause_requested` or `:resume_requested` when no outside-block native notice
was observed, including cancellation after possible dispatch. Native notices
use `:pause` and `:resume`. Loss counts are unknown (`dropped_bytes: nil`);
resume does not replay skipped output. Guarded notification-looking text stays
in its reply body.

Close the old control connection, then explicitly call
[`server.open_control(session: ref, reconnect: old_connection)`](https://libtmux.org/en/ruby/latest/reference/libtmux-server-open_control/) to reconnect
within the same binding and session. The replacement has a new `generation`
and retains `previous_generation`. Every new subscription begins with a
`:reconnect` gap containing both generations and an unknown loss count. Old
subscriptions stay closed, and requests are never replayed. Event sequences
describe one connection's observations, not durable pane history.

### Coverage and verification

Typed command coverage includes hierarchy creation/listing; rename, split,
resize, swap, join, break, respawn, and layout operations; link operations;
options/hooks/environment, capture/send/paste/pipe/buffers, copy commands,
display/source-file/wait-for. It does not establish complete flag parity or
every compatibility cell; consult the workflow results. RBS validation checks declarations;
installed signature consumers check selected real arguments, blocks and
return values. [Executable recipes](../../docs/recipes.md) run
against installed artifacts; the documentation gate renders YARD and guides
and checks local destinations and fragments. The [public method inventory](../../docs/reference/api.md)
links exported methods to source and behavioral contracts. These consumer
checks do not establish whole-program static typing.
