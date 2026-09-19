# Ownership and errors

An entity reference contains a binding identity, kind and tmux-assigned ID.
Window links also retain session and index context. A snapshot can describe
one window at several indexes without creating several window identities.
Names are query values, not substitutes for stable command targets.

A borrowed binding retains its private socket route. Replacing the public
socket does not authorize following a new server. Closing the binding retires
owned clients and pipes and preserves the borrowed daemon. A server started
with `Server.start` owns its daemon and temporary directory as well. Handles,
Async tasks and subscriptions cannot be transferred to another process or
scheduler as if their ownership were unchanged.

| Failure or empty value | Meaning |
| --- | --- |
| Empty `Selection` / `one_or_nil` returns `nil` | A valid complete local selection has no matching record |
| `NoMatchError` / `MultipleMatchesError` | `one` cannot establish exactly one match |
| `InvalidFilterError` / `FieldDecodeError` | Criteria or wire values do not satisfy the declared schema |
| `IncompleteSnapshotError` | Required coverage is unavailable; do not infer absence |
| `TargetNotFoundError` | The guarded target no longer matches its identity/context |
| `Cancelled` / `DeadlineExceeded` | The requested wait ended; delivery evidence determines possible effects |
| `SubscriptionOverflow` / gap event | A bounded stream cannot establish uninterrupted delivery |
| `Workspace::ApplyError` | Inspect its immutable result ledger before deciding whether to compensate |

Operation errors report a phase and delivery evidence: `not_sent`,
`possibly_sent`, or `observed`. An observed nonzero exit still needs its
command result. Cleanup diagnostics accompany failures; cleanup failure is
not a successful close. A cancelled mutating request can already have effects.
A timed-out WAIT lock request can still acquire its queued remote lock after
a later unlock; retiring the client does not roll back tmux's command queue.

Workspace compensation is explicit. It removes only a positively created
session whose current windows and panes all belong to the creation ledger,
checked in the same tmux command turn. A borrowed window or pane moved into
that session prevents destructive compensation. Arbitrary shell effects
cannot be rolled back, and an unacknowledged creation is never guessed by name.

Parsing errors and ordinary inspection redact payloads. Explicit results,
captures, plans and canonical exports contain the requested data, including
commands or normalized paths; callers control their storage and display.

See [execution modes](modes.md) and [workspace details](../gems/libtmux-workspace/README.md).
