# Public behavior

The [method inventory](api.md) maps every exported project method to one of
these contracts and its source. The [field catalog](fields.md) defines each
metadata field's type, wire spelling, null sentinel and relation coverage.
The shipped RBS files define argument and return shapes; this page describes
I/O, defaults, ownership, empty results and failure behavior.

Unless a section says otherwise, live core operations block the calling
thread, use a five-second total operation deadline and accept `cancel: nil`.
Async facades perform those operations on their owning scheduler. A deadline
includes admission and all commands needed by one operation; it does not
make a compound operation transactional. Cancellation retires owned clients,
not effects already queued at tmux. Local values, equality, hashes and
inspection perform no tmux I/O. Explicit raw bytes and exports can contain
caller data even when diagnostic inspection omits it.

## Endpoints

`Endpoint.new`, `Server.new` and `Server.open` select one endpoint at
construction. Precedence is an explicit `socket_path` or `socket_name`, then
nonempty `LIBTMUX_SOCKET_PATH`, nonempty `LIBTMUX_SOCKET_NAME`, nonempty `TMUX`,
then tmux's named `default` socket. Supplying both explicit selectors raises
`ArgumentError`. Empty environment selectors count as absent. Invalid
selected values fail without trying lower-precedence selectors.

Paths must be absolute. Names reject separators, NUL, empty strings, `.` and
`..`. Named sockets use `socket_directory`, captured nonempty `TMUX_TMPDIR`,
then `/tmp`, followed by `tmux-UID`. Filesystem traversal preserves missing
components and symlink parents. The TMUX parser splits its final two commas,
retains commas in the path, and accepts a positive ASCII decimal PID with a
nonnegative session ID (optional `$`) or the job sentinel `-1`.

`env:` supplies the complete child environment. Omit it to snapshot the host;
pass `ENV.to_h.merge(...)` for overrides. Nil values remove keys, and empty
string values remain empty. Construction freezes copied keys and values,
resolves the executable through that map's PATH (or `/usr/bin:/bin` when
absent), and removes TMUX and TMUX_PANE from child launches. Later host or map
changes cannot redirect clients or change their environment. `environment`
returns the frozen child map; it can contain secrets. Core subprocesses,
control clients, Async clients and terminal attachment use this snapshot.
Terminal attachment replaces TERM with its explicit `term:` value.

`Endpoint.from_env` delegates to the same constructor. Endpoint equality
compares executable and socket path; it does not establish daemon identity.
The `environment:` option on session/window/pane creation changes tmux's pane
environment, separate from the client's `env:` map. No API changes host ENV.

## Borrowed bindings

`Server.new` and `Server.open` bind an existing endpoint through a private
socket route. They do filesystem I/O, but do not start a daemon. The route
pins the selected socket incarnation; replacing the public path or restarting
there does not authorize retargeting. Ownership of the private directory is
exclusive; deliberate same-user tampering is outside this ownership contract.

Defaults admit 32 command requests and four control connections. `open` with
a block closes the binding and returns the block's value; without a block it
returns a caller-owned binding. A missing/replaced socket raises a typed
binding error. References from a separate binding are not interchangeable,
even when descriptors name the same public path. `endpoint` and `owned?` are
local accessors.

## Owned daemons

`Server.start` creates a unique temporary directory and socket, runs a
foreground tmux daemon with explicit configuration, and returns its binding
or yields it to a block. The default configuration is empty, the executable
is `tmux`, and the startup deadline is five seconds. Readiness uses filesystem
events, followed by a real client command. Unsupported platform readiness
fails explicitly; support still requires the platform matrix.

The returned binding owns that daemon, clients and files. Closing it or
leaving the block retires those resources. Startup errors and cancellation
clean up partially established ownership. `owned?` distinguishes this case
from a borrowed binding; it does not grant ownership of another daemon.

An explicit `endpoint:` publishes that owned daemon at the selected path. The
library starts the daemon in a private subdirectory beside the endpoint and
uses an atomic hard link to publish its socket. An occupied path raises
`Errno::EEXIST`, including a competing library startup, without replacing the
existing endpoint. tmux reports its private startup path in `socket_path`.
Callers must control the selected directory; same-user tampering with that
private directory remains outside the ownership contract.

For named endpoints, startup creates only the `tmux-UID` directory with mode
0700. Its parent must exist. An existing UID directory must be a real
directory owned by the current UID with no other-user permission bits; group
permissions are allowed. Explicit paths never create parents. A missing or
removed root fails without choosing `/tmp`. Close checks socket identity
before removing a published path and reaps its owned child before removing
its private directory. It retains caller-provided parent directories.

## Closing bindings

`Server#close` stops admission, requests cancellation of owned clients and
controls, waits within `close_timeout: 0.5`, then releases the private route.
A borrowed daemon remains running. An owned daemon is retired after its
clients. Incomplete cleanup raises a typed error and remains retryable; a
successful close is idempotent. Closing from the binding's active request is
rejected. In a forked child, close releases inherited local descriptors
without killing the parent's processes or removing its files.

## Killing daemons

`Server#kill` explicitly submits `kill-server` to the bound daemon and returns
a command result. It can destroy a borrowed daemon and all of its sessions;
this mutation is separate from closing the local binding. Successful client
status is command evidence, not a substitute for closing local resources.

## Session scopes

`Server#with_session` creates a session, yields it, then kills that captured
session ID on normal return or an exception. It returns the block result and
requires a block. It accepts the creation options of `new_session` except
`receipt:`. The cleanup uses a fresh default command deadline and no cancelled
body token. It leaves other sessions and the borrowed daemon running.

If both the body and cleanup raise, `CleanupError` retains their exception
objects as `body_error` and `cleanup_error`. A cleanup failure alone propagates
as its original exception. `Server.open` uses the same paired-error outcome
if its block and binding close both fail. A paired lifecycle failure also exposes the receipt-backed owner through `CleanupError#recovery`; retry its `close`. Successful owner close is idempotent. A caller retaining only a borrowed session handle can still call its raw `kill`; repeating that raw command reports that the session is absent.

## Entity references

An `EntityRef` is an immutable binding key, entity kind and tmux-assigned ID.
A window-link reference also retains its session and index. Equality and
hashing use that identity, not names or current focus. Constructors are
private; creation and captured metadata produce references.

A `CreationReceipt` contains the created entity, initial window and pane,
and command result. Those IDs come from the same framed creation reply;
later lookups do not prove that an observed child was created by the caller.
Ordinary creation returns the entity handle unless `receipt: true` is
requested where supported.

## Live handles

Handle accessors and `Server#session`, `#window`, `#pane` and `#window_link`
validate reference kind and binding without checking current existence.
Window-link `window` and `session` accessors preserve that binding context.
Handles are command targets, not caches of changing metadata. Subsequent I/O
can raise `TargetNotFoundError` after the entity disappears or its guarded
link context changes. Names are never fallback command targets.

## Raw commands

`Server#run` submits an argv array without a shell. Raw tmux separators,
formats and aliases retain their native meaning; leading endpoint flags are
rejected. Input defaults to empty bytes. The core bounds argv to 256 KiB,
stdin/stdout to 1 MiB each and stderr to 256 KiB, with separate half-second
cleanup and drain bounds. Async scope limits are configurable.

It returns `CommandResult`, including a nonzero client status; typed
operations raise `CommandError` for a failed command. Capacity, deadline,
spawn, decoding and cancellation failures carry delivery evidence. No raw
command automatically retries or rolls back a possibly dispatched effect.

## Command evidence

`CommandResult` retains binary stdout/stderr, argv, client PID, final
`Process::Status` and elapsed time. `text(invalid: :strict)` explicitly decodes
stdout and can raise `FieldDecodeError`; `invalid: :replace` scrubs invalid
UTF-8 and bytes remain available. `TerminalResult` retains
status, PID and elapsed time without captured terminal output. Their
`success?` delegates to the final client status and `delivery` is `observed`.
Neither result proves completion of a program running inside a pane.

## Diagnostics

`diagnostics` returns a deeply frozen local Hash from a server, Async scope,
control connection or subscription. It performs no tmux I/O, emits no log or
callback, and includes no paths, command arguments, pane bytes or identifiers.
Snapshots remain readable after close under the object's original process,
thread and scheduler ownership rules. Each snapshot describes one owner;
separate calls do not form an atomic view across owners.

Core server `admitted_requests` and `reserved_process_slots` count admitted
requests, including retirement. `control_connections` counts registrations
retained by that server, including closed controls until pruning or close.
These are ownership counts, not a census of live OS processes.

Async scope snapshots distinguish admitted and waiting requests from active
process slots. Slots remain charged through retirement. Reserved request bytes
cover admitted argv/input; retained output bytes include pending process and
map results. `maps` counts registered map operations; `control_connections`
counts controls that have not retired. The Async server delegates to its scope
and preserves the base Server keys: reserved slots include waiting admissions,
and `limits.close_timeout` is the scope's join budget, twice its cleanup timeout.

Control snapshots report admitted, incomplete, queued, writing and
awaiting-reply requests, reserved wire bytes and retained parsed reply bytes.
Completed replies remain charged until consumed. Parser framing buffers and
caller-owned returned values are outside retained reply accounting.
`stderr_received_bytes` is cumulative, not a retained buffer size.
`subscription_count` includes closed subscriptions retained by the connection.
Stopping, finished and cleanup-error counts describe connection retirement.

Subscription snapshots report queued events, retained event bytes, pending
gaps, reliable overflow, mode and closed state. Overflow leaves the reliable
prefix readable; explicit close discards it. Every snapshot includes the
owner's configured limits. Counts are current values, not historical peaks.
Result `elapsed_seconds` and structured error `phase`, `delivery` and
`cleanup_errors` supply per-operation evidence; snapshots do not retain timing
histories or estimate process liveness.

## Command groups

`run_group` submits ordered argv groups through one client. Execution is not
transactional; earlier commands can mutate tmux before a later failure.
`GroupResult#result` carries aggregate client evidence. Its per-step entries
remain `unknown`, since final client status does not establish each command's
result. WAIT commands and hooks can introduce interleaving. `success?` means
aggregate client success only.

## Creation

`new_session`, `new_window` and `split` return exact tmux-assigned handles.
`command` requires a nonempty argv array. A single executable is protected
from tmux's single-string shell interpretation; shell execution requires an
explicit shell argv. Names and cwd are escaped against tmux format expansion;
environment values are literal strings. Environment defaults to empty, cwd
to unspecified, and new windows/splits use `focus: false`.

A supplied cwd is checked as a local directory before dispatch; concurrent
filesystem changes can still trigger tmux's native fallback. Window indexes
are explicit when provided and collisions fail. Initial session window
index changes require a subsequent guarded link operation. `size` is a
positive cell count or percentage string; split direction is required.
`Pane#split` targets that pane, while `Window#split` uses the active pane in
that explicit window context. Receipts are available for session/window
creation. Errors can leave dispatched entities without an observed receipt.

## Live acquisition

`list_sessions`, `list_windows`, `list_panes` and `list_window_links` perform
explicit tmux reads and return arrays of handles. Server methods use global
scope; session/window methods constrain it. Empty arrays represent an empty
successful read, and native listing order is retained. Reads can race with
concurrent mutation and do not establish atomic graph coverage.

`list_clients` returns captured client records. Client tty/name/PID/creation
time observations are not incarnation-safe command references; client refs
and implicit selection of a current/latest client are unsupported.

## Snapshot acquisition

`Server#snapshot` reads a bounded metadata graph and returns `Snapshot`;
`Entity#snapshot` acquires that graph and resolves the exact reference.
Acquisition records its interval, constituent reads and coverage. It does not
claim one atomic instant. Clients are optional and omitted by default. Limits
default to 1 MiB total bytes, 10000 rows and 64 KiB per field.
Malformed framing or typed values fail explicitly rather than producing
partially trusted rows. Identity changes fail instead of following a new
server. Repeated calls acquire fresh evidence.

## Captured records

Snapshots, scalar readers, relations and `resolve` perform no tmux I/O.
Captured membership is immutable and replayable. Record equality includes
capture identity, so equal live IDs from separate captures need not compare
equal. `raw(field)` exposes captured bytes; typed readers validate UTF-8 and
types. Only catalog-declared empty sentinels become `nil`.

A relation uses the captured graph and preserves its declared cardinality.
Missing coverage raises `IncompleteSnapshotError`; unsupported coverage
raises `UnsupportedFeatureError`. Empty complete relations remain empty.
`resolve` checks binding, kind and identity. `ClientSnapshot#ref` raises
`UnsupportedFeatureError`; a client observation cannot become a command
reference merely by retaining it. See the field catalog for every generated
reader and relation.

## Criteria

`FilterExpr.build`, entity-specific `Where.build`, and `from_json` validate
the whole bounded criteria tree before use, including inactive OR branches.
They reject unknown keys/operators, wrong entity types and ambiguous wire
aliases. Boolean composition returns immutable expressions. Evaluation,
`call`, `===` and `to_proc` are local and enforce captured coverage.

Comparisons use catalog types; null is distinct from empty text. Relation
quantifiers preserve correlated child predicates and complete-empty
semantics. `to_h`/`to_json` export the versioned wire form and retain byte/tree
bounds; inspection omits literal payloads. `json_schema` reads the installed
schema file without tmux I/O.

## Selections

`Selection` captures array membership without refreshing it. `each`, Ruby
block `select`/`filter`/`find_all`, and `reject` preserve order; filtering
returns another selection. Without a block, enumeration methods return an
Enumerator. `to_a` returns a separate array of the same record objects.

`where` accepts validated criteria and requires an entity schema. `one`
raises `NoMatchError` or `MultipleMatchesError` unless exactly one record
matches; `one_or_nil` returns nil only for zero matches and still rejects
ambiguity. `exists?`, size and emptiness are local. Criteria/retrieval methods
do not accept blocks or mixed positional/keyword criteria.

## Source query plans

`explain_panes` validates criteria and returns an immutable plan without tmux
I/O. `pushdown: :auto` and `:never` currently use full graph capture followed
by local evaluation. The explanation reports capture requirements, residual
criteria and rejected optimization reasons. `:required` is marked
nonexecutable because no exact tmux predicate compiler has passed the
required differential checks.

## Source query execution

`search_panes` executes the corresponding explicit acquisition plan and
returns a captured `Selection`. Required unsupported pushdown raises before
I/O. Other snapshot limits and deadline options apply to acquisition; local
criteria evaluation does not refresh or silently weaken coverage.

## Formats

`display` accepts authored tmux format text and performs I/O. Entity methods
supply exact reference context; server `target: nil` explicitly uses tmux's
current context. With a target, identity is checked in the same response so
a missing target cannot masquerade as a successful empty display. The result
contains raw formatted bytes. Formats can execute native tmux format jobs;
this API does not reinterpret them as inert text.

## Entity removal

Entity `kill` methods submit the native removal operation. A session kill
can affect all its member windows/panes. Optional `expected_windows` and
`expected_panes` must be supplied together and constrain membership in one
server queue turn; unexpected membership prevents removal. This guard is
used by workspace compensation to preserve borrowed objects. It does not
turn unrestricted kill into a reversible operation.

## Entity mutation

Rename, resize, layout, select, swap, join/move, break-out and respawn methods
perform explicit targeted operations and return their declared command or
handle result. Destination references must share the binding. Pane
join/move require direction and default `before: false`. Resize defaults to
one cell when using a direction and leaves unspecified dimensions unchanged;
zoom is opt-in. Respawn requires a command, defaults `kill: false`, and
accepts the same cwd/environment handling as creation. Layout/focus changes
are observable mutations, not local handle edits.

Layout selection accepts native names, unambiguous native abbreviations and
saved layouts beginning with four hexadecimal checksum digits and a comma.
Unknown or ambiguous names and malformed headers raise `ArgumentError` before
mutation; tmux validates the remaining checksum and geometry. Mirrored names
require tmux 3.5+, otherwise raising `UnsupportedFeatureError`. Name resolution
may read the version under the operation's shared deadline. The five base names
and framed saved layouts need no version read.

## Cancellation tokens

`Cancellation.new` creates a caller-owned pipe without starting threads.
`cancel` is thread-safe, irreversible and wakes requests passed this token;
`cancelled?` reports its state. Neither call waits for those requests. Join all
users before `close`, which retires the pipe. Repeated cancel/close is safe;
their return values are unspecified. Do not read or close `reader` directly.
A forked child may close inherited descriptors; querying or cancelling the
parent's token raises `ClosedError`. See [ownership](../ownership-errors.md)
and the [executed example](../../examples/cancel.rb).

## Window links

Link operations preserve session/index/window identity together. `move`,
`swap`, `select`, `unlink`, link-specific display and scoped access guard that
context before mutation. Creating a link requires an explicit index;
collisions are not silently replaced. `unlink(force: false)` follows native
last-link refusal, while explicit forced unlink can destroy the window.
A window shared by several links is still one window. Removing a window
through `kill` affects its links according to tmux semantics.

## Pane input and capture

`send_text` sends literal text without interpreting key names; `send_keys`
uses native key names. Successful dispatch does not establish shell
completion. `capture` returns raw command evidence and defaults to the
visible screen with all capture flags false. Start/end may be integers or
`"-"`; alternate, mode-screen and pending capture modes are mutually
exclusive. Version-dependent flags are checked before dispatch.

`paste` requires a buffer and defaults `delete: false`, `bracketed: false`,
`separator: nil`. Native newline conversion is CR unless a separator is
provided. Bracketed output also depends on terminal bracket-mode state;
requesting it alone does not guarantee bracket markers.

## Pane pipes

`pipe` accepts authored shell command text, defaults to output only, and
closes an existing pipe when `shell_command: nil`. Input/output directions
are explicit. `only_if_closed` follows native `pipe-pane -o` toggle behavior:
when a pipe already exists, it is closed and no replacement starts. The
command result establishes tmux dispatch, not completion of the piped program.

## Copy mode

`copy_mode` enters or changes native pane copy mode; scrolling, mouse drag,
exit-on-bottom, cancellation and page-down flags default false. A source pane
is optional and must have valid binding identity. `copy_command` sends a
native copy-mode command and its arguments. Unsupported flags or commands
fail explicitly; no emulated text-selection behavior is claimed.

## Options and hooks

Obtaining an options/hooks accessor is local; get/list/set/unset/run perform
I/O at its explicit scope. Server options default to server scope and hooks
to global session scope. Entity/window-link accessors preserve exact context.
`list` defaults `inherited: false`; option `get` defaults true and requires an
index when multiple array entries exist. An absent option raises
`NoMatchError`; an empty present value remains distinct.

Set accepts strings, integers and booleans, with booleans encoded as on/off.
Append defaults false. Hook text is authored tmux command syntax, and `run`
executes it. Inherited hook acquisition is unsupported. Array indexes,
inheritance and presence are retained in `OptionValue`, not flattened away.

## Option values

Option-value accessors are local. `raw` preserves bytes, and `as` explicitly
converts to `:bytes`, `:string`, `:integer` or `:boolean`. Invalid UTF-8 or
invalid numeric/boolean spellings raise `FieldDecodeError`; unknown requested
types raise `ArgumentError`. Booleans accept on/off and 1/0. Missing values,
empty values and inherited values have separate metadata.

## Environment

Server and session environment methods perform explicit acquisition or
mutation at their scope. Names are validated; values are literal strings.
`hidden: false` is the default where supported. Unset is an explicit
operation rather than a nil-valued set. Reading an explicitly unset variable
returns nil; an absent variable can raise a native command error. An existing
empty value remains empty bytes.

## Buffers

Named buffers use explicit names and binary data. Write/read/delete/list
perform tmux I/O without a temporary file. Read returns command bytes;
listing returns captured native buffer metadata in its declared shape.
Absent names are command failures, while an existing empty buffer is valid.
The binding owns the command client, not the buffer's future lifetime.

## Wait channels

`wait_for` defaults `action: :wait` and accepts explicit native signal/lock/
unlock actions. It blocks or yields according to the execution mode and uses
the shared deadline/cancellation rules. Killing a waiting client does not
roll back server queue effects: an already queued lock can still acquire
after a later unlock. Use event signaling for coordination, not sleeps.

## Source files

`source_file` submits an explicitly authored tmux configuration path.
Configuration syntax, aliases, hooks and commands execute at the server;
this is not an inert parser. Paths are escaped as literal tmux arguments.
A failure can follow earlier effects, and successful client status does not
promise completion of detached jobs started by the configuration.

## Client switching

`switch_client(client:, session:)` resolves an explicit current tmux client
selector at command dispatch and switches it to an exact session reference
from this server binding. The selector is a nonempty string of at most 1024
bytes without NUL. Native matching checks attached clients by exact name,
full TTY path or TTY path without `/dev/`, after trimming one trailing colon.
If several clients match, tmux selects its first match. Missing selectors
raise `CommandError`; the library never omits `-c` or chooses a latest client.

This is a current-selector operation, not a retained client capability.
A reconnect or replacement matching that selector is eligible at dispatch;
client snapshots still cannot establish connection incarnation. The operation
does not acquire ownership of the selected client or its terminal. It uses
unshadowed builtin spelling and preserves the destination session environment
with `-E`. Timeout defaults to five seconds across alias discovery and the
command, with `cancel: nil`. The result is a `CommandResult`; cancellation
after dispatch remains uncertain and does not undo a switch. Async inherits
this command through its scheduler-owned runner.

## Terminal attachment

`attach` requires an exact session reference, a caller-supplied open terminal
IO and TERM value. It creates an owned interactive client and blocks until
that client exits. `read_only` defaults false and `timeout` defaults nil;
cancellation is explicit. Cleanup restores borrowed terminal modes and
preserves the daemon. Output remains on the terminal and the return value is
`TerminalResult`. No terminal or latest client is inferred by the library.

## Control connections

Prefer `Server#open_control(session: ref)` so the binding accounts for the
connection. Blocks close it on exit; without a block the caller must close
it. Low-level constructors require an internal binding and exact session ID.
The connection retains its own socket route, client and pipes. Core uses an
owned reader thread; Async uses tasks on its scope scheduler.

`exchange` accepts one bounded authored command line and returns
`GuardedReply`. Defaults are 32 admitted exchanges, 256 KiB command/line and
stderr bounds, 1 MiB queued command/reply bounds, and 32 subscriptions. Owned
completed-but-unconsumed exchanges remain charged until transfer to callers.
Malformed frames, EOF, overflow and cancellation can terminate the connection.
Close defaults to half a second and never kills the borrowed daemon.
Generation/PID/cleanup accessors describe this connection only. Reconnect
creates a new generation and reports a continuity gap; it is not replay.

## Control evidence

`GuardedBlock` preserves opening/body/closing bytes and guard identifiers.
`guard_success?` describes `%end` versus `%error`, not shell completion.
`GuardedReply` contains blocks within request boundaries and reports
`attribution: :boundary_window`; unsolicited hooks can share that interval.
It intentionally has no command-result success predicate.

Native `run-shell` output routing depends on tmux: 3.3a–3.4 writes it into
pane view mode; 3.2a and 3.5+ can emit it outside reply blocks as events.
The adapter preserves this behavior. Shell output resembling an unmatched
control terminator fails the connection closed when it reaches the raw stream.

`ControlEvent` preserves raw bytes plus decoded kind, data, pane and sequence
where available. Gaps expose lost sequence/byte evidence or a continuity
reason; optional fields remain nil when absent. Value constructors and
accessors are local and do not validate a live server's ownership.

## Control subscriptions

`subscribe` returns a connection-owned bounded stream. Defaults are reliable
mode, 1 MiB and 1024 events, with no pane filter. Reliable overflow raises
`SubscriptionOverflow`; tail mode emits explicit gaps. A slow subscriber
never blocks the connection reader. `next(timeout: nil)` waits indefinitely
until an event, finish or failure; explicit timeout is bounded. `each` yields
until completion, propagating exceptions from the caller's block.

Close releases buffered events and wakes waiters. EOF is `StopIteration` for
`next`; stream failures remain errors. `each` without a block returns an
Enumerator. Streams are process-owned, and Async
streams also require their original scheduler/thread. Retained returned
events are caller-owned and outside subscription buffer accounting.

## Control flow

`pause_output` and `resume_output` operate on an exact pane ID in the control
connection and return guarded reply evidence. Native flow control is
capability-gated; unsupported tmux versions refuse it. Events spanning
pause/resume or reconnect include explicit continuity evidence. They do not
promise lossless replay of output omitted by the server.

## Async scope

`Async.open` requires an existing core server and a live caller-owned Async
parent task. It yields a scope and closes its tasks/clients on exit while
preserving the borrowed core server. Scope construction defaults to four
active requests, 32 admitted requests and four controls. Byte and cleanup
limits are explicit constructor keywords. Queued requests count against
capacity and deadline budgets.

`scope.server` creates scheduler-bound handles through the Async facade.
Inherited operations share core targeting and result contracts but yield on
this scheduler. Using facades/streams on another scheduler, thread or process
raises `ClosedError`. Closing the facade closes its scope. Incomplete cleanup
is reported; repeated successful close is harmless.

## Async map

`Scope#map` requires a block, limits concurrent tasks, and returns results in
input order. Defaults use the scope concurrency, at most 1024 items, and the
scope output-byte limit. Results count against retained bytes before return;
a custom `result_bytes` callable supports application values. Failure or
caller cancellation stops sibling work and retires owned clients. Empty
input returns an empty array; unbounded input cannot bypass item/byte limits.

## Async unsupported operations

The Async server explicitly refuses `start` and interactive `attach`.
Create an owned core server before opening the Async scope, and use the core
terminal attachment API with an explicit terminal. These methods do not
silently fall back to a blocking implementation on the scheduler.

## MCP application

`Application` requires an application-owned Async server facade and an
explicit public endpoint alias. Default policy enables capabilities and
snapshot only; every mutation or observation tool requires explicit opt-in.
The application retains at most 16 captures and 8 MiB by default, with a
30-second capture TTL, five-second request deadline and 1 MiB response bound.
Mutations require at least 4096 response bytes for result/error evidence.

`tools` returns SDK tool classes; `sdk_server` creates the configured SDK
server without starting transport. Official SDK schema validation occurs on
first exposure/use, with both input and output schemas checked before any
operation dispatch. Handshake discovery needs only tool metadata. `call`
validates the schema and policy and returns an SDK response with structured
success/error data, delivery and mutation effects where relevant. Errors
omit raw input payloads. Close releases retained captures and tracking
resources, not the borrowed Async scope or daemon. Calls and close require
the creating scheduler/thread/process.

Screen observation requires an empty effective capture hook. On tmux 3.2a–3.4,
applications must coordinate hook configuration changes with captures and
screen waits because sparse-array inspection is a separate preflight.
tmux 3.5+ retains the hook check in the capture queue. Removing the selected
session link refuses the operation on all versions; it cannot select another
session's hook context.

## MCP transport

`StdioTransport` borrows caller IO streams and a live Async parent. `run`
starts owned reader/writer/request tasks; it cannot be restarted. Defaults
admit four active and 32 total requests, with 1 MiB frames and 4 MiB queued
request/output bytes. Request timeout defaults to 30 seconds, and write and
cleanup timeouts to half a second. The CLI selects its own five-second
request default.

The official SDK handles protocol discovery, envelopes and tool responses.
Notifications and requests retain bounded output ordering. Oversize frames,
invalid protocol, EOF and cancellation close or reject work according to
its delivery state. `send_response` and `send_notification` use the same
output accounting. Server-initiated `send_request` explicitly raises
`UnsupportedFeatureError`. Close retires owned tasks and restores the
SDK transport binding; it does not close caller streams or the scheduler.

## MCP CLI

`CLI.run` parses an argument array and borrows explicit `--socket` or
`--socket-name`; it never starts a daemon. It owns protocol tasks/clients,
uses the caller's stdin/stdout/stderr, and keeps stdout protocol-only.
Default tools remain read-only; repeated `--enable-tool` opts into supported
operations. Help/version exit zero, invalid arguments exit two, execution
failures exit one, and interruption exits 130. The library entry point
returns the integer status; the installed executable exits with it.

## Workspace parsing

`Workspace.parse` is inert and requires format and base directory;
`Workspace.load` reads a regular bounded file and infers JSON/YAML from its
extension unless format is explicit. Relative cwd values normalize against
that base. The plain declared tmuxp-style subset is version one; optional
profile/version must appear together. Unknown features, duplicate keys,
YAML tags/aliases and invalid types are rejected, without Ruby/ERB execution.

Defaults bound input/normalized bytes to 1 MiB, depth to 32, nodes to 10000,
strings to 64 KiB, windows to 128 and panes to 1024. Environment expansion is
off by default; opt-in `${NAME}` expansion uses only the supplied mapping.
Shell command text remains authored text. `to_h` returns the immutable
canonical document; it includes normalized paths/expanded values and can be
reloaded. Errors report a structural path without echoing private values.

## Workspace plans

`plan(snapshot: nil)` and `Plan.new` create immutable ordered steps without
tmux I/O. An optional snapshot adds binding/conflict preconditions but is
not a promise that future state will match. Steps retain explicit operation,
arguments, produced symbolic IDs and effect category. Plan/step accessors,
Data constructors, `members` and exports are local. Exports can contain
commands and normalized paths; inspection summarizes without printing them.
No planning method implicitly applies the plan.

## Workspace apply

`Plan#apply` explicitly authorizes authored configuration commands. It
requires an existing core server and defaults to a five-second total
deadline, `cancel: nil`, and `compensate: false`. It checks binding/conflicts,
then executes ordered individually attributable operations. Shell command
sending is recorded as dispatch only, not program completion.

Session options precede subsequent window/pane creation. On tmux 3.2a–3.6,
the reused initial pane keeps the global history limit inherited at creation;
later panes use the configured session value. Tmux 3.7+ updates existing grids
when `history-limit` changes. Apply preserves global options and initial IDs.

Creation receipts populate a ledger only with positively returned IDs.
Failure raises `ApplyError` carrying completed steps, known creations,
failed action and uncertainty. Opt-in compensation removes only positively
created objects, guarded against newly linked/joined borrowed members; an
unproven cleanup is refused. Compensation cannot undo shell effects or
unknown dispatched creations and has its own bounded cleanup allowance.

## Workspace results

`ApplyResult` and its Effect values expose immutable known effects,
created references, failed step/action, cleanup errors and compensation
state. `success?` and `uncertain?` inspect that evidence locally. They do not
query tmux or refresh missing receipts. `ApplyError#result` retains the ledger
and `failure_class` identifies the wrapped failure class without exposing
its raw message. Explicit exports retain caller data; inspection is redacted.

## Workspace CLI

`CLI.run` implements validate, plan and explicit load. Ordinary validate/plan
remain inert except configuration reads; `plan --live` explicitly acquires a
snapshot to add preconditions. Load borrows an explicit server endpoint;
`--attach` opens the caller terminal for the explicit core attach operation.
`load --switch CLIENT` switches that explicit current native selector only
after apply succeeds. It preserves session environment and does not infer a
client from the caller's pane or terminal. It is mutually exclusive with
`--attach`; missing or invalid selector arguments fail before apply. A later
switch failure returns status three with the creation ledger and keeps the
created session. Library `Plan#apply` does not attach or switch clients.

The CLI supports human or JSON output and returns exit status: zero for
success, two for usage/configuration errors, three for partial/uncertain
effects, one for failures before effects including preflight conflicts, and 130
for interruption. Authored shell commands are authorized by load without a
second trust prompt. Output streams, directory and expansion environment can
be supplied to the library entry point.

## Errors

`LibTmux::Error` retains phase, delivery, process and structural context, plus
secondary cleanup diagnostics where available. `not_sent` means no dispatch;
`possibly_sent` preserves uncertainty; `observed` reports returned evidence.
Constructors/accessors are local. Raw `CommandError#result` can contain argv
or output even when a high-level message is sanitized.

Bindings reject stale/foreign targets, selections distinguish missing from
ambiguous matches, and schema/coverage/capability failures have separate
classes. Closing a block-owned resource preserves its original failure while
attaching supported cleanup diagnostics; a cleanup failure on a successful
path still raises. A failure is not evidence that server mutations rolled
back.

## Signature proof

`scripts/types` inventories exported classes/modules, including inherited
project methods and generated readers, and checks declaration presence,
constructor visibility, source locations and behavioral mappings. RBS
validation checks declaration consistency. Neither check infers all Ruby
implementation paths or proves semantic behavior.

The installed consumer executes selected calls against the shipped RBS with
RBS's runtime argument/block/return checker and concrete expected result
types. It prints the exact exercised method IDs per package. Array values are
checked without sampling; a deliberately wrong implementation return must be
rejected. Generic type variables and `untyped` declarations remain weaker
than concrete declarations. SDK objects have concrete consumer expectations,
while their shipped adapter signatures currently remain untyped.

The checker does not consume live Enumerators or monkeypatch frozen criteria
modules. It exercises observed paths, not every overload or exception path.
Checker-only dependencies are installed after each artifact's minimal
runtime import and executable recipes, so they cannot hide runtime dependency
omissions. Behavioral tests, real-tmux fixtures and the platform matrix remain
separate evidence.

## Lifecycle ownership and discovery

[Ownership, discovery and find or create](../lifecycle.md) documents receipt-backed server/session/window/pane ownership, created/reused results and bounded discovery with executable examples. `OwnedResource#use` closes at block exit, successful repeated close is harmless, and failed close retains `cleanup_error` for retry. `CleanupError#recovery` exposes the owner after a paired failure. Keep the client binding open until ownership cleanup completes. New APIs preserve the existing Ruby 3.3 minimum and add no dependencies.

Find-or-create calls serialize across handles in one Ruby process with deadline-bounded admission. Raw commands and other processes remain outside that gate. Discovery scans direct entries in explicit or captured current-user roots, reports per-path failures and exhausted bounds, skips symlinks and deduplicates hard links. Its clients use no-start mode. The Async facade uses the bound core transport for ownership and its native deferred-cancellation hook for receipt handoff; repeated forced task cancellation and runner crashes require outer fixture ownership.
