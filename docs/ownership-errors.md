# Ownership and errors

- A reference holds a binding identity, a kind and a tmux-assigned ID. Window
  links also keep session and index context, so one window at several indexes
  is still one window.
- Names are query values, not stable command targets.
- A borrowed binding keeps its private socket route. Replacing the public
  socket does not make it follow a new server.
- Closing a binding retires its clients and pipes and leaves a borrowed daemon
  running. A server from `Server.start` also owns its daemon and temporary
  directory.
- Handles, Async tasks and subscriptions stay with the process and scheduler
  that made them.

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

## Delivery

Operation errors report a phase and delivery evidence: `not_sent`,
`possibly_sent` or `observed`.

- An observed nonzero exit still needs its command result.
- A cancelled mutating request can already have effects.
- A timed-out WAIT lock request can still take its queued lock after a later
  unlock. Retiring the client does not roll back tmux's command queue.
- Cleanup diagnostics accompany failures. A cleanup failure is not a
  successful close.

## Cancellation

- Cancelling an owned command client sends TERM, then KILL if its exit is not
  observed, and reaps the child within the remaining cleanup deadline. There is
  no grace period for a TERM handler. Borrowed panes and daemons are never
  terminated.
- Pass `LibTmux::Cancellation.new` as `cancel:` to blocking requests. Calling
  `cancel` from another thread wakes every user of the token, and `cancelled?`
  stays true. Later requests with the token refuse before dispatch.
- A token can cancel several requests. It owns a pipe and starts no thread. Keep
  it open until every request using it has returned, join those callers, then
  call `close`. Closing does not join them.
- `cancel` and `close` are idempotent, and their return values are unspecified.
  `reader` belongs to the token: do not consume its bytes or close it. After a
  fork, a child can close its inherited descriptors but cannot query or cancel
  the parent's token.
- The [plain-Ruby example](../examples/cancel.rb) shows wakeup, delivery
  evidence and client reaping. Async tasks use `Task#cancel`, as the
  [Async example](../examples/async_cancel.rb) shows.

## Workspace compensation

- Compensation is explicit. It removes only a session the apply positively
  created, whose current windows and panes all belong to its creation ledger,
  checked in the same tmux command turn.
- A borrowed window or pane moved into that session prevents it.
- Arbitrary shell effects cannot be rolled back, and an unacknowledged creation
  is never guessed by name.

## Redaction

Parsing errors and ordinary inspection redact payloads. Explicit results,
captures, plans and canonical exports hold the data you asked for, including
commands and normalized paths. You control how it is stored and shown.

See [execution modes](modes.md) and the
[workspace README](../gems/libtmux-workspace/README.md).
