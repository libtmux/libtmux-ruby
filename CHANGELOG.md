# Changelog

## 0.1.0.alpha.3 (unreleased)

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
