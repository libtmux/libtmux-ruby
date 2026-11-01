# Changelog

Notable changes to `libtmux`.

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: pin an exact version to avoid a break.

The gems are released together at one version, so every release has a section
here. Changes that span gems, such as documentation, CI and release tooling, are
in the [main changelog](../../CHANGELOG.md).

## 0.1.2 (unreleased)

## 0.1.1 (2026-10-31)

- `Window#select_layout` accepts a JSON layout only on tmux 3.8 or newer, and
  raw `select-layout`, including control lines, now refuses one below tmux 3.8
  instead of sending it. The `UnsupportedFeatureError` names tmux 3.8 as the
  minimum; upgrade tmux, or apply a checksummed layout. (#67)
- **Behavior change:** `Endpoint.new`, `Server.new` and `Server.open` no longer
  need a socket. With no `socket_path:` or `socket_name:`, they pick the socket
  tmux picks when it is given none: the path in `LIBTMUX_SOCKET_PATH`, else the
  name in `LIBTMUX_SOCKET`, else the socket `TMUX` names inside tmux, else
  tmux's default socket. They raised `ArgumentError` before. A program started
  inside tmux that names no socket now reaches that tmux's server; pass
  `socket_name:` or `socket_path:` to keep it off, as a test suite should.
  `Endpoint.from_env` still follows `TMUX` alone. Two edge cases now match
  tmux: an empty `TMUX_TMPDIR` means `/tmp`, where `Endpoint.new(socket_name:)`
  raised, and `Endpoint.from_env` reads `TMUX_TMPDIR` only from the hash it is
  given and ignores a `TMUX` that starts with a comma, where it raised. (#71)

## 0.1.0 (2026-10-25)

No entries for `libtmux`.

## 0.1.0.alpha.3 (2026-10-24)

### libtmux

- Refuse commands that misbehave on one tmux release before they run: named
  buffer deletion and rename below 3.4, raw `break-pane` and colon or period
  names on exact 3.7, raw `split-window -p` on 3.4, and malformed layouts below
  3.4. `Pane#break_out` now works on exact 3.7 and for a sole pane. Refusals
  raise `UnsupportedFeatureError`. (#37)
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

## 0.1.0.alpha.2 (2026-10-18)

### libtmux

- Run on tmux 3.8 and tmux master (`next-3.9`). Snapshots decode metadata
  with line feeds, `select_layout` accepts the JSON layouts that 3.8-rc2 and
  later report, and owned servers start on releases that log more at startup.
  (#36)
- **Breaking:** `Server.new` now reads the daemon's tmux release and blocks
  for up to `version_timeout:` seconds (default five), so a socket with no
  daemon raises `TargetNotFoundError` at construction instead of at the first
  command. Read the result with the new `Server#tmux_version`. (#36)

## 0.1.0.alpha.1 (2026-09-20)

### libtmux

- Create sessions, windows and panes; arrange layouts, send text or keys, and
  capture output through Ruby handles. Manage options, hooks, environment
  values and binary buffers. [Quick start](../../README.md#quick-start).
- Start a private tmux server with `LibTmux::Server.start`, or borrow an
  existing socket with `Server.open`. Block exit cleans up owned clients;
  borrowed daemons stay running. [Ownership](../../docs/ownership-errors.md).
- Query immutable snapshots with `where`, `select`, `one`, `one_or_nil` and
  `Enumerable`, without further tmux calls. `WindowLink` addresses a window's
  placement in a session, including repeated links to the same window.
  [Queries](../../examples/list_filter.rb) · [Linked windows](../../examples/window_links.rb).
- Use command deadlines and cancellation tokens, or subscribe to bounded
  control-mode events with explicit overflow and gap reporting.
  [Execution modes](../../docs/modes.md).
