# Changelog

Notable changes that span more than one gem: documentation, CI, release tooling,
and the notes that cover a whole release. A change to one gem is in that gem's
changelog:

- [`libtmux`](https://github.com/libtmux/libtmux-ruby/blob/master/gems/libtmux/CHANGELOG.md)
- [`libtmux-async`](https://github.com/libtmux/libtmux-ruby/blob/master/gems/libtmux-async/CHANGELOG.md)
- [`libtmux-mcp`](https://github.com/libtmux/libtmux-ruby/blob/master/gems/libtmux-mcp/CHANGELOG.md)
- [`libtmux-workspace`](https://github.com/libtmux/libtmux-ruby/blob/master/gems/libtmux-workspace/CHANGELOG.md)

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: pin an exact version to avoid a break. The gems are released together
at one version, so a release has a section in each changelog.

## 0.1.2 (unreleased)

- The test suites, the matrix, the benchmark and the README runner run in a
  sandbox. Before anything starts, it removes `TMUX`, `TMUX_PANE` and every
  `LIBTMUX_SOCKET*` variable and makes an owner-only directory under `TMPDIR`
  or `/tmp` the `TMUX_TMPDIR`, so a test or command that names no socket
  reaches no server outside the run, now that a bare `Endpoint` picks one.
  A run that cannot do so stops with status 2. (#80)
- When a run ends, a tmux server left anywhere in the sandbox is stopped with
  `tmux -S <socket> kill-server` and the run fails, even if every test passed.
  The failure names the sockets and never an environment value. (#80)

## 0.1.1 (2026-10-31)

Applies a JSON layout only on tmux 3.8 or newer, and picks the socket tmux
would pick when a caller names none. Upgraders must pass `socket_name:` or
`socket_path:` to keep a program started inside tmux off that tmux's server,
and must give older tmux a checksummed layout instead of a JSON one.

## 0.1.0 (2026-10-25)

The first final release. Releases are numbered `0.1.N` from here on, so a
plain `gem install libtmux` installs it without `--pre`. The API is not
settled: pin an exact version to avoid a break.

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
- `ControlConnection#exchange` and its Async twin apply the same refusals to
  their command line, which they read as tmux does. A nameless `break-pane`
  over a control connection used to kill an exact 3.7 daemon. Raw
  `new-session -s`, `new-window -n` and `rename-*` with a colon or period in
  the name now raise `UnsupportedFeatureError` on exact 3.7, as the typed
  calls do, instead of returning tmux's failed result. (#37)

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
- **Breaking:** `PaneSnapshot#pid` can now be `nil`, because tmux 3.8 reports
  no PID for a dead pane. The type changes on every tmux release in the RBS
  signatures, the `where` schema and the field catalog, so typed callers must
  handle `nil`. MCP process tracking of a pane without a PID raises
  `TargetNotFoundError`. [Migration](https://github.com/libtmux/libtmux-ruby/blob/master/MIGRATION.md). (#36)

## 0.1.0.alpha.1 (2026-09-20)

Initial alpha of the Ruby tmux suite.

### libtmux-workspace

Each gem ships RBS declarations. The [API reference](docs/reference/api.md)
links public methods to their contracts; [executable recipes](docs/recipes.md)
cover the installed packages. See the [release guide](docs/releasing.md) for
coordinated version bumps and publishing.
