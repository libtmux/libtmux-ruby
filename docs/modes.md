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

## Servers

- `Server.open(socket_path: ...)` borrows a daemon through a pinned binding.
  With no socket named, it borrows the daemon tmux would pick. See
  [Endpoints](reference/behavior.md#endpoints).
- `Server.start` creates an owned daemon on a unique socket and closes it with
  the block.

## Results

- `CommandResult#success?` means the client exited successfully. Sending input
  does not show that a shell finished.
- A `GuardedReply` has no `success?`: `%end` ends a guard, and WAIT commands,
  aliases and hooks can change what finishes when. Its `boundary_window`
  attribution is weaker than per-command ownership.

## Control connections

- Concurrent calls pipeline complete requests on one connection. The writer can
  submit a later request while an earlier reply waits, and the reader assigns
  boundaries in the same order. Sequential calls still wait for each reply.
- Admission limits count every pending request and every completed request
  whose reply nobody has consumed.
- Cancelling after any request bytes are written closes the connection. Other
  written requests report `possibly_sent` delivery, and requests with no
  written bytes report `not_sent`. Nothing uncertain is replayed.
- A reliable subscription raises `SubscriptionOverflow` when it cannot keep the
  stream. A tail subscription emits a gap with the lost sequence and byte
  counts. Neither blocks the command reader behind a slow consumer.
- Limits apply to connection-owned buffers. Callers own the replies they keep.

## Captured queries

- A query evaluates the whole criteria tree before selecting rows, including
  inactive OR branches.
- Explain methods perform no I/O. Current source plans capture explicitly and
  evaluate locally. A required pushdown with no exact compiler fails rather
  than change semantics.

More: the [recipes](recipes.md) cover WAIT release, cancellation, overflow and
group failure.
