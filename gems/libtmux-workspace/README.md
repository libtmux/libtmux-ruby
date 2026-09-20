# libtmux-workspace

Load bounded YAML or JSON, inspect an immutable creation plan, then explicitly
apply it to an open libtmux server. This package is unreleased. The library
and installed command-line executable share the core
[compatibility matrix](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml);
consult its exact per-revision results.

The gem declares Ruby 3.3 or newer and depends on the same-version `libtmux`
gem, JSON 3.0 and Psych 5.5. See the repository's
[contribution guide](../../.github/CONTRIBUTING.md) for local builds and checks.
Imports and planning do not start tmux or run commands.

## Example

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
On tmux 3.2a–3.6, the reused initial pane retains the global `history-limit`
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

The locally built gem installs `libtmux-workspace`. `validate` and offline
`plan` do not contact tmux. Without a filename, discovery requires exactly one
`.tmuxp.yaml`, `.tmuxp.yml` or `.tmuxp.json` in the current directory.

```console
$ libtmux-workspace validate workspace.yaml
```

Human plans list ordered operations and their effects. `--json` prints the
same plan data as `Plan#to_h`, including configured command text and paths.

```console
$ libtmux-workspace plan \
    --json \
    workspace.yaml
```

`load` and `plan --live` require `--socket` for an existing server. This
detached creation example uses an explicitly supplied `TMUX_SOCKET` value:

```console
$ libtmux-workspace load \
    --socket "$TMUX_SOCKET" \
    --json \
    workspace.yaml
```

`--timeout` bounds each apply, live capture or subsequent switch operation
and defaults to 5 seconds.
`--compensate` enables guarded cleanup after apply failure. Environment
expansion requires both `--expand-environment` and explicit `--env NAME=VALUE`
arguments; ambient environment variables are not copied into that mapping.

`load --attach` opens the CLI's `/dev/tty` after creation and runs an owned
terminal client until the user detaches. It requires a valid `TERM`. Failure
to open or attach the terminal retains the successful apply ledger and
returns status 3. `load --switch CLIENT` switches the explicit current tmux
client selector to the created session after apply, preserving the session's
environment. It accepts a current client name, full TTY path or TTY path
without `/dev/`; native first-match behavior applies. A missing client fails
without fallback and retains the created session and ledger with status 3.
Missing or invalid selector arguments fail before creation. Use
`--switch=VALUE` for a selector beginning with `-`.

The selector is resolved at dispatch; a reconnect matching it is eligible.
It is not a captured client reference or proof of terminal ownership. Attach
and switch are mutually exclusive. Neither operation infers a latest client,
and library `Plan#apply` performs neither operation.

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
