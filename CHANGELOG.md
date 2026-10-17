# Changelog

## 0.1.0.alpha.2 (unreleased)

### libtmux

- Require tmux 3.3a or newer. `Server.open` and `Server.start` refuse an
  older daemon, including unpatched 3.3 and a daemon behind a newer client,
  with `UnsupportedFeatureError` before any requested command runs; the same
  applies to Async, MCP and the workspace CLI. Update the daemon, or point the
  endpoint at a supported one. tmux master (`next-3.9`) and release candidates
  are supported. [Supported tmux](docs/reference/behavior.md#supported-tmux).
- Support tmux 3.8: decode escaped line feeds in captured metadata, accept
  its JSON saved layouts in `select_layout`, and report the PID of a dead pane
  as `nil` (`PaneSnapshot#pid` is now `Integer?`).

### libtmux-mcp

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
  queries are enabled by default. [Server setup](gems/libtmux-mcp/README.md#start-the-server).
- Opt into screen captures, event-driven waits, creation, input and close
  tools. Snapshot cursors page one retained capture; resources expose metadata
  and pane screens. [Protocol example](examples/mcp_protocol.rb).
- Run scripts through `tmux_run` after explicitly enabling the tool and
  enrolling a zsh shell. Results distinguish stdout, stderr and observed
  completion. [Shell enrollment](gems/libtmux-mcp/README.md#run-authored-commands).

### libtmux-workspace

- Load YAML or JSON with `LibTmux::Workspace.load` or `.parse`, inspect a
  creation plan, then apply it explicitly. Supports the documented subset of
  tmuxp-style configuration. [Workspace example](examples/workspace_apply.rb).
- Validate, plan and load from the `libtmux-workspace` CLI; optionally attach
  or switch an explicit client after creation. `--version` reports the
  installed gem version without reading a configuration or contacting tmux.
  [CLI guide](gems/libtmux-workspace/README.md#command-line-interface).
- Inspect partial application through `ApplyError#result`. Optional
  compensation removes only a positively identified new session after
  checking that its windows and panes belong to the apply operation.
  [Failure results](gems/libtmux-workspace/README.md#apply-and-failure-results).

Each gem ships RBS declarations. The [API reference](docs/reference/api.md)
links public methods to their contracts; [executable recipes](docs/recipes.md)
cover the installed packages. See the [release guide](docs/releasing.md) for
coordinated version bumps and publishing.
