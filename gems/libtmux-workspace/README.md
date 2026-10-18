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

Load bounded YAML or JSON, inspect an immutable creation plan, then explicitly
apply it to an open libtmux server. The library
and installed command-line executable share the core
[compatibility matrix](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml);
consult its exact per-revision results.

[API reference](https://libtmux.org/en/ruby/latest/workspace/reference/) ·
[Command reference](https://libtmux.org/en/ruby/latest/workspace/cli/) ·
[Guides](https://libtmux.org/en/ruby/latest/workspace/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux-workspace)

</div>

Part of [libtmux for Ruby](https://github.com/libtmux/libtmux-ruby#readme).
Built on [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux).

Requires tmux 3.3a or newer to load or apply a plan.

- Validation and offline planning need no running daemon.
- When the daemon is older, `load` creates nothing and prints the refusal with
  the floor and the remedy, as text or in the `error.message` of the `--json`
  result, whose `error.kind` is `tmux_unsupported`.
- The gem declares Ruby 3.3 or newer and depends on the same-version
  `libtmux` gem, JSON 3.0 and Psych 5.5. See the repository's
  [contribution guide](../../.github/CONTRIBUTING.md) for local builds and
  checks.
- Imports and planning do not start tmux or run commands.

## Install

Install the alpha and its `libtmux-workspace` executable:

```console
$ gem install libtmux-workspace --pre
```

## Quick start

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

Check the file. `validate` reads no tmux state:

```console
$ libtmux-workspace validate workspace.yaml
```

```text
Workspace configuration is valid.
```

Print the ordered operations a load would run. Offline `plan` does not contact
tmux either:

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

## Use from Ruby

The [complete workspace program](../../examples/workspace_apply.rb) creates an
isolated server, applies this document and checks compensation after a later
failure. Calling `apply` authorizes the configuration's shell commands. This
excerpt runs inside that program's cleanup wrapper:

<!-- example: workspace_apply/main -->
```ruby
workspace = LibTmux::Workspace.load(File.join(__dir__, "workspace.yaml"))
plan = workspace.plan(snapshot: server.snapshot)
Example.check(server.list_sessions.size == 1, "planning changed tmux")
result = plan.apply(server: server)
Example.check(result.success?, "workspace apply failed")
Example.check(result.effects.any? { |effect| effect.outcome == :dispatch_only }, "shell dispatch overclaims completion")
crowded = LibTmux::Workspace.parse(JSON.generate({
  session_name: "crowded", windows: [{window_name: "small", panes: Array.new(40) { {} }}]
}), format: :json, base_directory: __dir__)
error = Example.raises(LibTmux::Workspace::ApplyError) do
  crowded.plan.apply(server: server, compensate: true)
end
Example.check(!error.result.created_refs.empty?, "failure lost partial creation ledger")
Example.check(error.result.compensation == :completed, "owned compensation failed")
Example.check(server.list_sessions.map(&:ref).include?(borrowed.ref), "borrowed session was removed")
```
<!-- /example -->

## Configuration

The plain declared subset has effective version 1. Optional `profile` and
`version` must appear together as `libtmux-ruby.workspace` and `1`.
`workspace.to_h` exports an immutable, normalized, reloadable configuration.
It contains expanded values and absolute directories; callers control its
storage and disclosure.

- Root: `session_name`, nonempty `windows`, `options`, `window_options`.
- Window: `window_name`, nonempty `panes`, `window_index`, `focus`, `layout`,
  `options`. Indexes are unique nonnegative integers; unspecified indexes use
  the lowest available value starting at the declared `base-index` or zero.
- Pane: a command string or a mapping with `focus`, `split`, `size`. Split is
  `horizontal` or `vertical`. Size is positive cells or `1%` through `99%`;
  neither applies to the initial pane. Explicit sizes cannot accompany a
  final named layout.
- Root, windows and pane mappings accept `start_directory`, `environment`,
  `shell_command` and `shell_command_before`. Environment maps merge from
  parent to child. Commands inherit unless overridden; before-commands append
  in parent-to-child order. Command values accept a string or string array.

At most one window and one pane per window can declare focus; each defaults
to the first. Layouts are `even-horizontal`, `even-vertical`, `main-horizontal`,
`main-vertical` and `tiled`. Unknown fields and unsupported features fail with
a `ConfigError` identifying their configuration position.

Session options accept boolean `status`, `mouse`, `renumber-windows`;
nonnegative `base-index`, `history-limit`, `status-interval`; and enumerated
`status-position` and `status-justify`. Window options accept boolean
`automatic-rename`, `allow-rename`, `remain-on-exit`, `synchronize-panes`,
`aggressive-resize`; nonnegative `pane-base-index`, `main-pane-width`,
`main-pane-height`; text `window-status-format`, `window-status-current-format`;
and enumerated `pane-border-status`. Option text remains tmux option text,
including any formats that tmux evaluates.
`pane-base-index` cannot exceed 65535; the other numeric options accept
integers through 2147483647.

YAML tags, anchors, aliases, duplicate keys, multiple documents and complex
mapping keys are rejected. JSON duplicate keys are rejected too. No Ruby,
ERB, plugins or callbacks are evaluated. Defaults bound source and canonical
bytes to 1 MiB, strings to 64 KiB, nesting to 32, nodes to 10,000, windows to
128 and panes to 1,024. The corresponding `max_*` parse/load keywords can
adjust these positive limits. Configuration files must be regular files.

`${NAME}` substitution is opt-in for directories and environment values:
pass `expand_environment: true, environment: {"NAME" => "value"}` to load or
parse. Only the supplied bounded mapping is consulted. Shell text and option
values are unchanged; `~` has no special path meaning. Missing variables fail
validation. Parsing checks path syntax; apply checks current accessibility.
Concurrent filesystem changes can still trigger tmux's cwd fallback.

## Apply and failure results

`workspace.plan(snapshot: snapshot)` retains that capture's binding identity
and rejects a captured name conflict. Every apply takes a fresh snapshot and
rechecks identity and name absence. The plan creates a new session; it does
not reconcile, replace or remove a preexisting workspace. The first window
and pane from each creation command are reused.

Apply is synchronous, uses one monotonic timeout across its core operations,
and accepts a cancellation token. Panes run `/bin/sh`; explicit initial pane
environment overrides do not modify the session environment. Window indexes,
splits, options, layout and focus follow the plan's order. Temporary local
option overrides disable renumbering and pane synchronization during setup;
the plan then restores declared values or inheritance.

Session options apply before subsequent windows and split panes are created.
On tmux 3.3a–3.6, the reused initial pane retains the global `history-limit`
inherited at session creation. Later panes use the configured session value.
For uniform history on these versions, configure the server's global value
before applying the workspace. Apply does not change global options or replace
the initial pane. On tmux 3.7+, setting the option also updates existing grids.

Shell commands are sent as literal text followed by Enter. Both insertion
and Enter are dispatch effects: embedded newlines can execute during text
insertion. Success proves tmux accepted the dispatch, not that a shell
command finished or succeeded. Shell commands can leave effects beyond tmux.

An `ApplyError` exposes an immutable `result`: completed step IDs, positively
identified `created_refs`, observed or dispatch-only effects, failed action,
uncertainty and cleanup diagnostics. Diagnostics omit command payloads and
paths. Lost creation replies stay uncertain; names are never used to guess
ownership. A caller may pass `compensate: true` to kill only the positively
returned new session on failure, after an atomic tmux guard proves that every
current window and pane has a positively identified created reference. Unknown
initial entities or borrowed entities moved into that session cause refusal.
Cleanup uses a separate 0.5-second budget. Compensation status is explicit and
cannot undo shell effects. The default
preserves partial state for inspection. Applying or compensating does not
close the supplied server binding.

## Command-line interface

The gem installs `libtmux-workspace`. Each command has a page in the
[command reference](https://libtmux.org/en/ruby/latest/workspace/cli/):
[validate](https://libtmux.org/en/ruby/latest/workspace/cli/validate/),
[plan](https://libtmux.org/en/ruby/latest/workspace/cli/plan/) and
[load](https://libtmux.org/en/ruby/latest/workspace/cli/load/).

- `validate` and offline `plan` do not contact tmux.
- `plan --live` captures a snapshot first. `load` and `plan --live` require
  `--socket` for an existing server.
- Without a filename, discovery requires exactly one `.tmuxp.yaml`,
  `.tmuxp.yml` or `.tmuxp.json` in the current directory.
- `libtmux-workspace --help` lists every option.

Check the installed gem version without reading a configuration or contacting
tmux:

```console
$ libtmux-workspace --version
```

Human plans list ordered operations and their effects. `--json` prints the
same plan data as `Plan#to_h`, including configured command text and paths:

```console
$ libtmux-workspace plan \
    --json \
    workspace.yaml
```

| Option | Effect |
| --- | --- |
| `--json` | Write one structured result or error object to stdout |
| `--socket PATH` | Select the existing server's socket for `load` or `plan --live` |
| `--live` | Capture a snapshot before planning |
| `--timeout SECONDS` | Bound each apply, live capture or switch operation; the default is 5 |
| `--compensate` | Run guarded cleanup after an apply failure |
| `--attach` | Attach this CLI's terminal after a successful `load` |
| `--switch CLIENT` | Switch an explicit current client to the new session after `load` |
| `--expand-environment` | Expand `${NAME}` in directories and environment values |
| `--env NAME=VALUE` | Supply a value for expansion; ambient variables are never copied |

Attach and switch:

- `load --attach` opens the CLI's `/dev/tty` after creation and runs an owned
  terminal client until you detach. It requires a valid `TERM`.
- `load --switch CLIENT` switches the explicit current tmux client selector to
  the created session after apply, keeping the session's environment. It
  accepts a current client name, a full TTY path or a TTY path without
  `/dev/`; native first-match behavior applies. Use `--switch=VALUE` for a
  selector that begins with `-`.
- A missing client, or a failure to open or attach the terminal, keeps the
  created session and the apply ledger and returns status 3. A missing or
  invalid selector argument fails before creation.
- The selector is resolved at dispatch, so a client that reconnects and matches
  it is eligible. It is not a captured client reference or proof of terminal
  ownership.
- Attach and switch are mutually exclusive. Neither infers a latest client,
  and library `Plan#apply` performs neither.

| Exit status | Meaning |
| --- | --- |
| 0 | Validation, planning or apply succeeded; requested attach/switch succeeded |
| 1 | Execution failed before known application effects |
| 2 | Configuration or arguments are invalid |
| 3 | Application was partial or uncertain, or a later attach/switch/cleanup failed |
| 130 | Interrupted; available effect ledger is retained |

JSON mode writes one result or error object to stdout. Apply errors include
`ApplyResult#to_h`; human errors write the diagnostic and any ledger to stderr.
Diagnostics omit configuration payloads. Explicit plan rendering and canonical
configuration export contain those values by design.
