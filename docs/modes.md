# Execution modes

| Mode | Wait and ownership | Result evidence |
| --- | --- | --- |
| Core command | Calling thread blocks; server binding owns each client and its pipes | `CommandResult` has binary stdout/stderr and final client status |
| Captured query | Snapshot acquisition performs explicit I/O; `Selection` filtering is local | Stable captured membership with acquisition interval and coverage |
| Command group | One client submits an ordered, nontransactional group | Aggregate final status; individual steps remain `unknown` |
| Core control | One owned reader thread drains the connection; each subscriber has limits | Guarded blocks between boundaries; hooks can share the interval |
| Async | Caller supplies an Async parent task; pipe I/O yields on its scheduler | Same command evidence, with bounded request admission and cancellation |
| MCP | Caller supplies transport streams, Async scope and tool policy | Versioned protocol envelopes and structured tool responses |
| Workspace | Parsing and planning are inert; apply performs ordered commands | Created-reference ledger, observed effects and explicit uncertainty |

Use `Server.open(socket_path: ...)` to borrow a daemon through a pinned
binding. `Server.start` creates an owned daemon on a unique socket and closes
it with the block. No API in these recipes chooses the default server.

`CommandResult#success?` means the client exited successfully. Sending input
does not establish shell completion. A `GuardedReply` has no `success?`:
`%end` terminates a guard, while WAIT commands, aliases and hooks can change
what finishes when. Its `boundary_window` attribution is deliberately weaker
than per-command ownership.

Concurrent control calls pipeline complete wire requests on one connection.
The writer can submit a later request while an earlier reply waits; the reader
assigns boundaries in the same order. Admission limits include all pending
and completed but unconsumed requests. Cancellation after any request bytes
are written closes the connection: other written requests have
`possibly_sent` delivery, and requests with no written bytes have `not_sent`.
No uncertain request is replayed. Sequential calls still wait for each reply.

Reliable control subscriptions raise `SubscriptionOverflow` when they cannot
retain the stream. Tail subscriptions emit a gap containing lost sequence
and byte evidence. Neither mode blocks the command reader behind a slow
consumer. Limits apply to connection-owned buffers; callers own the replies
they retain after return.

Captured queries evaluate the whole criteria tree before selecting rows,
including inactive OR branches. Explain methods perform no I/O. Current
source plans use explicit capture and local evaluation; unsupported required
pushdown fails rather than silently changing semantics.

See [the recipes](recipes.md) for event-based WAIT release, cancellation,
overflow and group-failure examples. No throughput comparison is claimed.
