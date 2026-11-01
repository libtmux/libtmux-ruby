<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Ruby workspace">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux-workspace

[Load][workspace-load] bounded YAML or JSON, inspect an immutable
[creation plan][workspace-plan-class], then explicitly
[apply][workspace-plan-apply] it to an open libtmux server.

[API reference](https://libtmux.org/en/ruby/latest/workspace/reference/) ·
[Command reference](https://libtmux.org/en/ruby/latest/workspace/cli/) ·
[Guides](https://libtmux.org/en/ruby/latest/workspace/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux-workspace)

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/ruby/latest/workspace/)
[![libtmux-workspace](https://img.shields.io/gem/v/libtmux-workspace?label=libtmux-workspace)](https://rubygems.org/gems/libtmux-workspace)

</div>

Part of [libtmux for Ruby](https://github.com/libtmux/libtmux-ruby#readme).
Built on [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux).

Check a workspace file, see the ordered steps a load would run, and create the
session on a running tmux server, from the `libtmux-workspace` command or from
Ruby.

Validation and offline planning need no running daemon, and imports start no
tmux process.

**Contents** — [Quick start](#quick-start) ·
[Write the file](#write-the-file) ·
[Create the session](#create-the-session) ·
[Failed apply](#recover-from-a-failed-apply) ·
[Attach or switch](#attach-or-switch-to-the-new-session) ·
[Scripts](#script-it) · [Leaves out](#what-it-leaves-out) ·
[Support](#support-and-status) · [Documentation](#documentation)

## Quick start

Install the gem and its `libtmux-workspace` executable. It needs Ruby 3.3 or
newer, and tmux 3.3a or newer to load a plan:

```console
$ gem install libtmux-workspace
```

Save this declared subset of tmuxp-style data as `workspace.yaml`. Relative
directories resolve against the configuration file's directory.

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

Check the file. [`validate`][cli-validate] reads no tmux state:

```console
$ libtmux-workspace validate workspace.yaml
```

```text
Workspace configuration is valid.
```

Print the ordered operations a load would run. Offline [`plan`][cli-plan] does
not contact tmux either:

```console
$ libtmux-workspace plan workspace.yaml
```

```text
offline_create: 11 ordered steps
1. create_session session (creation)
2. set_session_option session (configuration)
3. set_window_option window:0 (configuration)
4. move_initial_window window:0 (configuration)
5. split_pane pane:0:0 (creation)
6. select_layout window:0 (configuration)
7. send_command pane:0:0 (dispatch_only)
8. unset_window_option window:0 (configuration)
9. select_pane pane:0:0 (configuration)
10. select_window window:0 (configuration)
11. unset_session_option session (configuration)
```

## Write the file

### [`Workspace.load`][workspace-load]: the declared subset

`load` reads a regular file of bounded size and infers JSON or YAML from its
extension. [`Workspace.parse`][workspace-parse] takes the text and a base
directory instead. Both return an immutable workspace:

- Root: `session_name`, nonempty `windows`, `options`, `window_options`.
- Window: `window_name`, nonempty `panes`, `window_index`, `focus`, `layout`,
  `options`.
- Pane: a command string, or a mapping with `focus`, `split` and `size`.
- Root, windows and panes accept `start_directory`, `environment`,
  `shell_command` and `shell_command_before`.
- Layouts are `even-horizontal`, `even-vertical`, `main-horizontal`,
  `main-vertical` and `tiled`.
- At most one window and one pane per window declare focus.
- Without a filename, the command looks for exactly one `.tmuxp.yaml`,
  `.tmuxp.yml` or `.tmuxp.json` in the current directory.
- An unknown field or an unsupported feature fails with a
  [`ConfigError`][workspace-configerror] that names its position in the file.
- YAML tags, anchors and aliases are rejected, and no Ruby, ERB, plugins or
  callbacks run.
- `${NAME}` substitution is opt-in: pass
  `expand_environment: true, environment: {"NAME" => "value"}` to `load` or
  `parse`, or `--expand-environment --env NAME=VALUE` to the command.
- [`workspace.to_h`][workspace-to_h] exports an immutable, normalized and
  reloadable configuration, with expanded values and absolute directories.

The full field, option and limit lists are in
[Workspace parsing][behavior-workspace-parsing].

## Create the session

### [`libtmux-workspace load`][cli-load]: build it on a running server

`load` needs a running server. It never starts one, so start a private server
with a keepalive session and no user configuration:

```console
$ WORKSPACE_TMP=$(mktemp -d)
```

```console
$ tmux -S "$WORKSPACE_TMP/tmux.sock" -f /dev/null new-session -d -s keepalive
```

Create the workspace's session on that socket. It stays detached:

```console
$ libtmux-workspace load \
    --socket "$WORKSPACE_TMP/tmux.sock" \
    workspace.yaml
```

```text
Workspace created; 11 steps completed. Shell commands were dispatched.
```

The new `work` session holds the `editor` window:

```console
$ tmux -S "$WORKSPACE_TMP/tmux.sock" list-windows -t work
```

Stop only the private server and remove its directory:

```console
$ tmux -S "$WORKSPACE_TMP/tmux.sock" kill-server
```

```console
$ rm -rf "$WORKSPACE_TMP"
```

Loading the same file again fails with status 1: a plan creates a new session
and never reconciles an existing one.

### [`Plan#apply`][workspace-plan-apply]: the same from Ruby

[`Workspace.load`][workspace-load] reads the file,
[`workspace.plan`][workspace-plan-method] plans it against a snapshot, and
`apply` creates the session. Calling `apply` authorizes the configuration's
shell commands.

The path below belongs to [the example file](../../examples/api/workspace_apply.rb)
under `examples/api/`; it loads `examples/workspace.yaml` in this checkout:

<!-- example: api_workspace_apply/main -->
```ruby
require "libtmux"
require "libtmux/workspace"

LibTmux::Server.start do |server|
  workspace = LibTmux::Workspace.load(File.expand_path("../workspace.yaml", __dir__))
  plan = workspace.plan(snapshot: server.snapshot)
  puts "planned steps: #{plan.steps.length}"
  result = plan.apply(server: server)
  puts "applied: #{result.success?}"
  puts "sessions: #{server.list_sessions.map { |session| session.snapshot.name }.join(', ')}"
end
```
<!-- /example -->

The program runs on a private server and prints:

```text
planned steps: 11
applied: true
sessions: work
```

- A snapshot makes the plan reject a name that already exists, and every
  `apply` takes a fresh snapshot and checks again.
- The plan creates a new session. It does not reconcile, replace or remove an
  existing one.
- Success shows that tmux accepted the dispatch of each shell command. It does
  not show that the command finished.

The [complete program](../../examples/workspace_apply.rb) also runs the
installed command with `--switch`. The contract is in
[Workspace apply][behavior-workspace-apply].

## Recover from a failed apply

### [`ApplyError#result`][workspace-applyerror-result]: what exists after a failure

A failed apply raises [`ApplyError`][workspace-applyerror]. Its immutable
`result` holds the completed step IDs, the
[`created_refs`][workspace-applyresult-created_refs] tmux returned, the
effects it observed, and the failed action. Pass `compensate: true` to remove
only the session the apply created:

<!-- example: api_workspace_failure/main -->
```ruby
require "json"
require "libtmux"
require "libtmux/workspace"

LibTmux::Server.start do |server|
  server.new_session(name: "borrowed", command: ["/bin/cat"])
  crowded = LibTmux::Workspace.parse(
    JSON.generate({session_name: "crowded", windows: [{window_name: "small", panes: Array.new(40) { {} }}]}),
    format: :json, base_directory: __dir__
  )
  begin
    crowded.plan.apply(server: server, compensate: true)
  rescue LibTmux::Workspace::ApplyError => error
    puts "failed action: #{error.result.failed_action}"
    puts "created a session: #{error.result.created_refs.key?('session')}"
    puts "compensation: #{error.result.compensation}"
  end
  puts "sessions: #{server.list_sessions.map { |session| session.snapshot.name }.join(', ')}"
end
```
<!-- /example -->

That many panes do not fit in one window, so tmux refuses a split after the
session exists. It prints:

```text
failed action: split_pane
created a session: true
compensation: completed
sessions: borrowed
```

- Compensation removes the new session only after a tmux guard shows that
  every window and pane in it has a positively identified created reference.
- An unknown initial entity, or a borrowed entity moved into the session,
  makes it refuse.
- Compensation cannot undo what shell commands did. Without it, the partial
  state stays for you to inspect.
- Diagnostics omit command payloads and paths. Names are never used to guess
  ownership.

The command takes `--compensate`. The contracts are in
[Workspace results][behavior-workspace-results].

## Attach or switch to the new session

### [`load --switch`][cli-load]: move a client to the session

- `load --attach` opens the CLI's `/dev/tty` after creation and runs an owned
  terminal client until you detach. It requires a valid `TERM`.
- `load --switch CLIENT` switches a current tmux client to the created session
  after apply, keeping the session's environment.
- `CLIENT` is a client name, a full TTY path or a TTY path without `/dev/`.
  Use `--switch=VALUE` for a selector that begins with `-`.
- A missing client, or a failure to open or attach the terminal, keeps the
  created session and returns status 3.
- Attach and switch are mutually exclusive, and neither infers a latest
  client. The library's [`Plan#apply`][workspace-plan-apply] does neither.

The selector rules are in [Client switching][behavior-client-switching].

## Script it

### [`--json`][cli-load]: one object on stdout

Check the installed gem version without reading a configuration or contacting
tmux:

```console
$ libtmux-workspace --version
```

Human plans list ordered operations and their effects. `--json` prints the
same plan data as [`Plan#to_h`][workspace-plan-to_h], including configured
command text and paths:

```console
$ libtmux-workspace plan \
    --json \
    workspace.yaml
```

[`load`][cli-load] and `plan --live` act on an existing server. Without
`--socket`, they use the socket in `LIBTMUX_SOCKET_PATH`, else the name in
`LIBTMUX_SOCKET`, else the server `TMUX` names when run inside tmux, else
tmux's default socket. When both variables are set, the path wins, an empty
variable counts as unset, and `--socket` ignores both. A command run from a tmux
pane with none of these set acts on that pane's server. This detached creation
example names its socket with a `TMUX_SOCKET` value:

```console
$ libtmux-workspace load \
    --socket "$TMUX_SOCKET" \
    --json \
    workspace.yaml
```

`libtmux-workspace --help` lists every option. The
[command reference][ws-cli] has a page for each command.

| Option | Effect |
| --- | --- |
| `--json` | Write one structured result or error object to stdout |
| `--socket PATH` | Select the existing server's socket for `load` or `plan --live`; the default follows the socket variables, then `TMUX`, then tmux's default socket |
| `--live` | Capture a snapshot before planning |
| `--timeout SECONDS` | Bound each apply, live capture or switch operation; the default is 5 |
| `--compensate` | Run guarded cleanup after an apply failure |
| `--attach` | Attach this CLI's terminal after a successful `load` |
| `--switch CLIENT` | Switch an explicit current client to the new session after `load` |
| `--expand-environment` | Expand `${NAME}` in directories and environment values; requires `--env` |
| `--env NAME=VALUE` | Supply a value for expansion; ambient environment variables are not copied |

| Exit status | Meaning |
| --- | --- |
| 0 | Validation, planning or apply succeeded; requested attach/switch succeeded |
| 1 | Execution failed before known application effects |
| 2 | Configuration or arguments are invalid |
| 3 | Application was partial or uncertain, or a later attach/switch/cleanup failed |
| 130 | Interrupted; available effect ledger is retained |

Apply errors include [`ApplyResult#to_h`][workspace-applyresult-to_h]. Human
errors write the diagnostic and any ledger to stderr. Diagnostics omit
configuration payloads; plan rendering and canonical export contain those
values by design.

## What it leaves out

- **Reconciliation.** A plan creates a new session and never replaces or
  removes an existing workspace. The contract is in
  [Workspace plans][behavior-workspace-plans].
- **Shell command completion.** Apply records a shell command as dispatched.
  Embedded newlines can execute while the text is inserted. See
  [Workspace apply][behavior-workspace-apply].
- **Rollback of shell effects.** Compensation removes only tmux objects the
  apply created. See [Workspace results][behavior-workspace-results].
- **Features beyond the declared subset.** Plugins, ERB and callbacks are
  rejected, and a [`ConfigError`][workspace-configerror] names the position.
- **A guessed client.** Attach and switch need an explicit client. See
  [Client switching][behavior-client-switching].

## Support and status

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelogs mark each break. Pin an exact version to avoid one.
See the [changelog](CHANGELOG.md), and the [main
changelog](https://github.com/libtmux/libtmux-ruby/blob/master/CHANGELOG.md)
for changes that span gems.

- **Ruby 3.3 or newer.** The gem depends on the same version of `libtmux`,
  JSON 3.0 and Psych 5.5.
- **tmux 3.3a or newer** to load or apply a plan.
- **Older daemons.** `load` creates nothing and prints the refusal with the
  floor and the remedy. With `--json`, the refusal is in `error.message` and
  `error.kind` is `tmux_unsupported`.
- **Linux, including WSL, and macOS.** The library and the command share the
  core [compatibility workflow][compat]: Ruby 3.3, 3.4 and 4.0 with tmux 3.3a
  through 3.8 on Ubuntu 24.04, with per-revision results. A push and a pull
  request run the oldest and newest of those releases, 3.3a and 3.8, and a
  release runs all of them. macOS is supported on a best-effort basis, and CI
  coverage for it is highly limited.
- **History limit.** On tmux 3.3a to 3.6 the reused initial pane keeps the
  global `history-limit`. Set the server's global value before you apply to
  get one history size.

## Documentation

| | |
| --- | --- |
| [Reference](https://libtmux.org/en/ruby/latest/workspace/reference/) | Every public workspace class and method |
| [Command reference][ws-cli] | A page for `validate`, `plan` and `load` |
| [Guides][workspace-guides] | Validate, inspect and explicitly apply a plan |
| [Topics][workspace-topics] | Format, planning boundaries, effects and failure ledgers |
| [Public behavior][behavior-workspace-parsing] | Parsing, plans, apply, results and the command |
| [Recipes][doc-recipes] | The workspace plan, load and failure program |

[behavior-client-switching]: ../../docs/reference/behavior.md#client-switching
[behavior-workspace-apply]: ../../docs/reference/behavior.md#workspace-apply
[behavior-workspace-parsing]: ../../docs/reference/behavior.md#workspace-parsing
[behavior-workspace-plans]: ../../docs/reference/behavior.md#workspace-plans
[behavior-workspace-results]: ../../docs/reference/behavior.md#workspace-results
[cli-load]: https://libtmux.org/en/ruby/latest/workspace/cli/load/
[cli-plan]: https://libtmux.org/en/ruby/latest/workspace/cli/plan/
[cli-validate]: https://libtmux.org/en/ruby/latest/workspace/cli/validate/
[compat]: https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml
[doc-recipes]: ../../docs/recipes.md
[workspace-applyerror]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-applyerror/
[workspace-applyerror-result]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-applyerror-result/
[workspace-applyresult-created_refs]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-applyresult-created_refs/
[workspace-applyresult-to_h]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-applyresult-to_h/
[workspace-configerror]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-configerror/
[workspace-guides]: https://libtmux.org/en/ruby/latest/workspace/guides/
[workspace-load]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-load/
[workspace-parse]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-parse/
[workspace-plan-apply]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-plan-apply/
[workspace-plan-class]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-plan-1qko/
[workspace-plan-method]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-plan-1c5c/
[workspace-plan-to_h]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-plan-to_h/
[workspace-to_h]: https://libtmux.org/en/ruby/latest/workspace/reference/libtmux-workspace-to_h/
[workspace-topics]: https://libtmux.org/en/ruby/latest/workspace/topics/
[ws-cli]: https://libtmux.org/en/ruby/latest/workspace/cli/
