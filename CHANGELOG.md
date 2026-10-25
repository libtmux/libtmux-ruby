# Changelog

## 0.1.0 (unreleased)

### libtmux

- Releases are numbered `0.1.N` from `0.1.0`, with no `-alpha` or other
  prerelease tag unless the maintainer asks for one. The API is not
  settled: any release may change or remove exported identifiers, the
  changelog marks each break, and an exact version pin avoids one. The
  READMEs and the release guide say so.
- The README says control connections need tmux 3.7 and links
  `capabilities.json`. (#55)
- The behavior reference lists which nested commands escape the guard, on
  which releases and how each fails, and the `break-pane-misnames-windows`
  summary in `capabilities.json` says to name a nested `break-pane` on exact
  3.7 or upgrade. (#55)
- The release guide's examples use a version placeholder. (#55)

## 0.1.0.alpha.3 (2026-10-24)

Keeps the tmux 3.3a floor and refuses, before anything runs, the commands a
supported release mishandles. Upgraders must check `Server#supports_control?`
before opening a control connection, which now needs tmux 3.7, and handle
`StopIteration` from `ControlSubscription#next` and the new `pane_died` code
from `tmux_wait`.

- CI no longer runs macOS. macOS stays supported on a best-effort basis, and CI
  coverage for it is highly limited, so a macOS-only regression is not caught
  before merge. (#49)

### libtmux

- **Breaking:** Control connections need tmux 3.7 or newer. `open_control`,
  reconnect and Async control raise `UnsupportedFeatureError` on an older
  daemon before any client attaches, and nothing else leaves the 3.3a floor.
  Check the new `Server#supports_control?` first, or poll with `Pane#capture`.
  [Optional features](docs/reference/behavior.md#optional-tmux-features). (#37)
- Refuse commands that misbehave on one tmux release before they run: named
  buffer deletion and rename below 3.4, raw `break-pane` and colon or period
  names on exact 3.7, raw `split-window -p` on 3.4, and malformed layouts below
  3.4. `Pane#break_out` now works on exact 3.7 and for a sole pane. Refusals
  raise `UnsupportedFeatureError`. (#37)
- `ControlConnection#exchange` and its Async twin apply the same refusals to
  their command line, which they read as tmux does. A nameless `break-pane`
  over a control connection used to kill an exact 3.7 daemon. Raw
  `new-session -s`, `new-window -n` and `rename-*` with a colon or period in
  the name now raise `UnsupportedFeatureError` on exact 3.7, as the typed
  calls do, instead of returning tmux's failed result. (#37)
- Raw `refresh-client -l`, in `Server#run` or a control line, raises
  `UnsupportedFeatureError` below tmux 3.6a. On 3.3a, asking an attached
  terminal for its clipboard stops the server, and on 3.4 through 3.6 the
  server stops when that client leaves before its terminal answers. (#37)
- Snapshots and the daemon identity check no longer fire `after-display-message`
  hooks. (#37)
- Record every tmux release gate in one internal registry and emit it as the
  root `capabilities.json` manifest, which the docs site reads for its
  capability pages. `Window#select_layout` raises `UnsupportedFeatureError`,
  not `ArgumentError`, for a JSON layout below tmux 3.8-rc2. (#37)

### libtmux-async

- `ControlSubscription#next` ends the stream with `StopIteration`. It used to
  return `nil` at the end of a stream, because `Kernel#loop` swallowed the
  exception. (#37)

### libtmux-mcp

- `tmux_wait` with `screen_contains` polls the pane screen on tmux older than
  3.7 instead of attaching a control client, and uses control events from
  3.7. (#37)
- `tmux_wait` with `screen_contains` joins wrapped rows, so text that the pane
  width split across rows now matches. (#37)
- `tmux_wait` fails with the new `pane_died` code, `delivery: observed` and
  the last rows read in `error.capture`, when the pane or its tmux server ends
  before the text appears. That case used to return `stale_target`, or
  `observation_lost` after a killed server. A control stream that ends while
  the pane lives, such as after a detach, returns `observation_lost` instead
  of raising `NoMethodError`. (#37)

## 0.1.0.alpha.2 (2026-10-18)

Requires tmux 3.3a or newer, checked against the running daemon, and runs on
tmux 3.8 and master. Upgraders must handle a `nil` `PaneSnapshot#pid` and a
`Server.new` that contacts the daemon while it constructs.

### libtmux

- Require tmux 3.3a or newer. `Server.open`, `Server.new` and `Server.start`
  raise `UnsupportedFeatureError` before any command runs when the daemon is
  older, including unpatched 3.3, 3.1 and 3.0. The daemon's release decides,
  not the client's, so a newer client does not accept an older daemon. The
  error says to upgrade tmux and restart the server, or pin the previous
  libtmux release. Async, the workspace CLI and `libtmux-mcp` refuse the same
  way, and `workspace load` prints that message in its text and `--json`
  output, where `error.kind` is `tmux_unsupported`.
  [Supported tmux](docs/reference/behavior.md#supported-tmux). (#36)
- Run on tmux 3.8 and tmux master (`next-3.9`). Snapshots decode metadata
  with line feeds, `select_layout` accepts the JSON layouts that 3.8-rc2 and
  later report, and owned servers start on releases that log more at startup.
  (#36)
- **Breaking:** `PaneSnapshot#pid` can now be `nil`, because tmux 3.8 reports
  no PID for a dead pane. The type changes on every tmux release in the RBS
  signatures, the `where` schema and the field catalog, so typed callers must
  handle `nil`. MCP process tracking of a pane without a PID raises
  `TargetNotFoundError`. [Migration](https://github.com/libtmux/libtmux-ruby/blob/master/MIGRATION.md). (#36)
- **Breaking:** `Server.new` now reads the daemon's tmux release and blocks
  for up to `version_timeout:` seconds (default five), so a socket with no
  daemon raises `TargetNotFoundError` at construction instead of at the first
  command. Read the result with the new `Server#tmux_version`. (#36)

### libtmux-mcp

- `libtmux-mcp` reports an unsupported tmux daemon as refused to start,
  before any session exists. If the daemon changes while the server runs, a
  tool call returns an `unsupported` result with `delivery: not_sent` and a
  fixed line that names the floor and the remedy. (#36)
- Declare object roots in tool output schemas so clients using the
  2025-11-25 protocol accept the `tools/list` response with MCP SDK 1.5.1.

## 0.1.0.alpha.1 (2026-09-20)

Initial alpha of the Ruby tmux suite.

### libtmux

- Create sessions, windows and panes; arrange layouts, send text or keys, and
  capture output through Ruby handles. Manage options, hooks, environment
  values and binary buffers. [Quick start](README.md#quick-start).
- Start a private tmux server with `LibTmux::Server.start`, or borrow an
  existing socket with `Server.open`. Block exit cleans up owned clients;
  borrowed daemons stay running. [Ownership](docs/ownership-errors.md).
- Query immutable snapshots with `where`, `select`, `one`, `one_or_nil` and
  `Enumerable`, without further tmux calls. `WindowLink` addresses a window's
  placement in a session, including repeated links to the same window.
  [Queries](examples/list_filter.rb) · [Linked windows](examples/window_links.rb).
- Use command deadlines and cancellation tokens, or subscribe to bounded
  control-mode events with explicit overflow and gap reporting.
  [Execution modes](docs/modes.md).

### libtmux-async

- Run commands concurrently inside an application-owned Async task with
  `LibTmux::Async.open`. `Scope#map` bounds concurrency and returns results
  in input order. [Concurrent capture](examples/async_cancel.rb).
- Use Async control connections and event subscriptions. Scope exit retires
  owned clients and tasks while preserving the borrowed daemon.
  [Async guide](gems/libtmux-async/README.md).

### libtmux-mcp

- Serve an explicit tmux endpoint over MCP stdio with `libtmux-mcp`, or embed
  `Application` and `StdioTransport` in Ruby. Capability discovery and snapshot
  queries are enabled by default. [Server setup](gems/libtmux-mcp/README.md#quick-start).
- Opt into screen captures, event-driven waits, creation, input and close
  tools. Snapshot cursors page one retained capture; resources expose metadata
  and pane screens. [Protocol example](examples/mcp_protocol.rb).
- Run scripts through `tmux_run` after explicitly enabling the tool and
  enrolling a zsh shell. Results distinguish stdout, stderr and observed
  completion. [Shell enrollment](gems/libtmux-mcp/README.md#run-a-script-in-a-pane).

### libtmux-workspace

- Load YAML or JSON with `LibTmux::Workspace.load` or `.parse`, inspect a
  creation plan, then apply it explicitly. Supports the documented subset of
  tmuxp-style configuration. [Workspace example](examples/workspace_apply.rb).
- Validate, plan and load from the `libtmux-workspace` CLI; optionally attach
  or switch an explicit client after creation. `--version` reports the
  installed gem version without reading a configuration or contacting tmux.
  [CLI guide](gems/libtmux-workspace/README.md#script-it).
- Inspect partial application through `ApplyError#result`. Optional
  compensation removes only a positively identified new session after
  checking that its windows and panes belong to the apply operation.
  [Failure results](gems/libtmux-workspace/README.md#recover-from-a-failed-apply).

Each gem ships RBS declarations. The [API reference](docs/reference/api.md)
links public methods to their contracts; [executable recipes](docs/recipes.md)
cover the installed packages. See the [release guide](docs/releasing.md) for
coordinated version bumps and publishing.
