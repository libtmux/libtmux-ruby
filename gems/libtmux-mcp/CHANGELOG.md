# Changelog

Notable changes to `libtmux-mcp`.

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: pin an exact version to avoid a break.

The gems are released together at one version, so every release has a section
here. Changes that span gems, such as documentation, CI and release tooling, are
in the [main changelog](../../CHANGELOG.md).

## 0.1.2 (unreleased)

## 0.1.1 (2026-10-31)

- **Behavior change:** `libtmux-mcp` no longer needs `--socket` or
  `--socket-name`, and still refuses both together. Without a flag it serves
  the same choice as `Server.new`, so start it with `--socket-name` or
  `LIBTMUX_SOCKET` when an agent needs a server of its own. (#71)

## 0.1.0 (2026-10-25)

No entries for `libtmux-mcp`.

## 0.1.0.alpha.3 (2026-10-24)

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

### libtmux-mcp

- `libtmux-mcp` reports an unsupported tmux daemon as refused to start,
  before any session exists. If the daemon changes while the server runs, a
  tool call returns an `unsupported` result with `delivery: not_sent` and a
  fixed line that names the floor and the remedy. (#36)
- Declare object roots in tool output schemas so clients using the
  2025-11-25 protocol accept the `tools/list` response with MCP SDK 1.5.1.

## 0.1.0.alpha.1 (2026-09-20)

### libtmux-mcp

- Serve an explicit tmux endpoint over MCP stdio with `libtmux-mcp`, or embed
  `Application` and `StdioTransport` in Ruby. Capability discovery and snapshot
  queries are enabled by default. [Server setup](../../gems/libtmux-mcp/README.md#quick-start).
- Opt into screen captures, event-driven waits, creation, input and close
  tools. Snapshot cursors page one retained capture; resources expose metadata
  and pane screens. [Protocol example](../../examples/mcp_protocol.rb).
- Run scripts through `tmux_run` after explicitly enabling the tool and
  enrolling a zsh shell. Results distinguish stdout, stderr and observed
  completion. [Shell enrollment](../../gems/libtmux-mcp/README.md#run-a-script-in-a-pane).
