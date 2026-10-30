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

`Endpoint.new` requires exactly one explicit socket path or socket name. It
expands the path and resolves `executable: "tmux"` through PATH without
starting a client. Socket names use `socket_directory`, then `TMUX_TMPDIR`,
then `/tmp`, with tmux's per-user directory. Invalid paths/names or an
unavailable executable raise `ArgumentError`.

`Endpoint.from_env` is the explicit opt-in to environment discovery: it uses
the socket from `TMUX`, or tmux's `default` socket name when absent. The
ordinary constructor does not infer that choice. Descriptor equality compares
resolved executable and socket path; it does not establish server identity.

## Borrowed bindings

`Server.new` and `Server.open` bind an existing endpoint through a private
socket route. They do filesystem I/O and one version probe of the running
daemon (see [Supported tmux](#supported-tmux)), but do not start a daemon. The
route pins the selected socket incarnation; replacing the public path or
restarting there does not authorize retargeting. Ownership of the private
directory is exclusive; deliberate same-user tampering is outside this
ownership contract.

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
Owned startup has Linux and Darwin readiness backends.

The returned binding owns that daemon, clients and files. Closing it or
leaving the block retires those resources. Startup errors and cancellation
clean up partially established ownership. `owned?` distinguishes this case
from a borrowed binding; it does not grant ownership of another daemon.

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

Reading an ID or a ref performs no I/O. `list_*`, `snapshot` and the command
methods do.

## Supported tmux

The suite supports tmux 3.3a and newer. Releases compare in full, patch
letter included, so 3.3 is below the minimum. A `next-X.Y` development build
or an `-rc` candidate ranks below the release it names, and a report that is
not a numbered release, such as `master`, is refused as unrecognized. The
refusal names what the daemon or executable reported.

tmux release candidates are not supported: a feature can require one only
until its release ships, and a candidate such as `X.Y-rcN` ranks below
`X.Y`. See [Release candidates](https://libtmux.org/en/tmux/guides/tmux-support/#release-candidates).

`Server.new` and `Server.open` read the connected daemon's release through the
private route with `run-shell -C`, which fires no tmux hook. The configured
client's `-V` output is not consulted, so a newer client cannot accept an older
daemon. `Server.start` reads the configured executable's `-V` report before
every owned daemon starts; its refusal says "the executable reports" where the
others say "connected version". An unsupported or unreadable release raises
`UnsupportedFeatureError` with `phase: :admission` and `delivery: :not_sent`.
Here `:admission` means "refused before dispatch": no requested command ran.
A probe that fails for another reason, such as a deadline or a spawn error,
keeps its own error class and phase and reports `delivery: :not_sent`. A socket
with no running daemon raises `TargetNotFoundError`. Each refusal says to
upgrade tmux and restart the server, or to pin the previous libtmux release.

A daemon older than tmux 3.2 has no `run-shell -C`. A 3.1 daemon answers the
probe with the `run-shell` usage line, and a 3.0 daemon makes the client report
that the server is too old; both raise the same refusal. These daemons keep
the client's stdout pipe open after the client exits, so the probe sends its
stdout to the null device and reads the answer from stderr and the exit
status.

Every raw command, typed operation, snapshot, Async call, workspace apply and
MCP request dispatches through a binding that passed this version check. Each
dispatched command list begins with an `if-shell` fence naming the checked
release. If the daemon behind the route stops reporting it, tmux rejects a
private marker before any requested command runs and the call raises
`UnsupportedFeatureError`. On tmux 3.5 and newer that rejection fires
`command-error`. Control connections and terminal attachments use the same
route and are not probed again: the route pins the checked daemon's socket
inode, and an interactive client's output cannot carry a fence marker.

The probe and the fence spell `run-shell` and `if-shell` as the unique
prefixes `run-shel` and `if-shel`, because tmux resolves a `command-alias`
entry by exact name: an alias named for the full command, which the guarded
link operations already work around, cannot reach them. The version check
tests the result once. An `if-shel` with a true condition around
`run-shel -C <marker>` must report the marker's parse error, with no failing
command and so no hook. An alias or a future tmux command that shadows either
prefix refuses the server with `UnsupportedFeatureError` instead of silently
disabling the fence. Aliases added after the version check, and other
redefinitions of built-ins, are outside the contract.

`version_timeout:` (default five seconds) bounds each version read made by
`Server.new`, which blocks while it runs.

`Server#tmux_version` returns the checked release text, such as `3.7d` or
`next-3.9`.

`LibTmux::Support` exposes the version check: `Support::MINIMUM`,
`Support.require_supported(text)` and `Support.server_version(server)`, also
reachable as `Support::Versions`. Here "support" means tmux version support,
not helper code.

## Optional tmux features

Optional features keep their own requirements. The checked daemon release
decides each one before any effect, and a refusal raises
`UnsupportedFeatureError` with `delivery: :not_sent` and `phase: :admission`.
None of them raises the 3.3a minimum for subprocess operations, snapshots,
workspace builds or MCP tools that do not need them.

| Feature | Daemon | Older or affected daemon | State |
| --- | --- | --- | --- |
| Control connections: `open_control`, Async control, reconnect | 3.7 and newer | Refused before a control client attaches | Refusal qualified by tests; acquisition operative with synchronization |
| MCP `tmux_wait` condition `screen_contains` | Control events from 3.7 | Polls the pane screen with `capture-pane` and attaches no control client; both paths join wrapped rows and fail a pane or server that ends first as `pane_died` | Qualified in the stated evidence |
| Named buffer deletion and rename (`delete_buffer`, `delete-buffer -b`, `set-buffer -b -n`) | 3.4 and newer | Refused: an absent name acts on an unrelated buffer | Refusal qualified by tests |
| Named paste and delete (`Pane#paste` with `delete: true`) | 3.3a and newer | Exact lookup, available | Qualified in the stated evidence |
| `Pane#break_out` | All supported | Exact 3.7 applies the name again after the move; 3.3a through 3.5 read a sole pane's window back because break-pane prints no ID | Qualified in the stated evidence |
| Raw `break-pane`, including `ControlConnection#exchange` lines | All except exact 3.7 | Refused on exact 3.7, which crashes without a name | Refusal qualified by tests |
| Session and window names with `:` or `.`, typed or in raw `new-session -s`, `new-window -n` and `rename-*` | All except exact 3.7 | Refused on exact 3.7 before dispatch, with the typed call's error | Refusal qualified by tests |
| Raw `split-window -p` | All except 3.4 | Refused on 3.4; typed splits always send `-l N%` | Refusal qualified by tests |
| Raw `refresh-client -l`, including `ControlConnection#exchange` lines | 3.6a and newer | Refused: tmux 3.3a stops when it asks an attached `xterm-256color` or `tmux-256color` terminal for its clipboard, and 3.4 through 3.6 stop when that client leaves before its terminal answers | Refusal qualified by tests |
| Malformed layouts | 3.4 and newer | tmux 3.3a faults on a malformed header, so `select_layout` and raw `select-layout` accept only a checksummed layout or a unique built-in name | Refusal qualified by tests |
| JSON layouts (`layout-json`) in `select_layout` and raw `select-layout`, including `ControlConnection#exchange` lines | 3.8 and newer | Refused before dispatch: tmux before 3.8 cannot read a JSON layout | Refusal qualified by tests |

tmux 3.8 saves layouts as JSON.

The release floors in this table come from one internal registry.
`scripts/emit-capabilities` writes it to `capabilities.json`, which the
docs site reads for its capability pages.

`Server#supports_control?` reports whether the checked daemon accepts control
clients, so callers can choose a polling path before asking for one.

The version check, the snapshot's server identity and the break-out read-back avoid
`display-message`, so a user's `after-display-message` hook never runs as a side
effect of them.

Raw `run` reads literal argv, including `;` separated batches and tmux's
command abbreviations, for the buffer, `break-pane`, `split-window`,
`select-layout` and name rows. `ControlConnection#exchange` applies the same rows to
its command line, which it reads as tmux does: quotes and backslashes group
words, an unquoted `;` ends a command, and a brace block is one word.
Tmux command strings nested inside another command are
not checked: the command given to `if-shell` or `run-shell -C`, the body of a
brace block, a `$VARIABLE` that expands to a command, and the contents of
`command-alias` entries. The guard does not parse these recursively, so a
nested form reaches tmux unchanged, and each command below fails the way tmux
fails on that release:

| Nested command | Affected releases | Failure class |
| --- | --- | --- |
| `break-pane` without `-n` | exactly 3.7 | The server exits when the pane's window has other panes. |
| `select-layout` with a layout string that has no checksum header | 3.3 and 3.3a | The server exits. Tmux 3.4 answers "invalid layout". |
| `refresh-client -l` | below 3.6a | The server exits: at once on 3.3a when an attached client's TERM is xterm-256color or tmux-256color, on 3.4 to 3.6 when that client leaves before its terminal answers. |
| `delete-buffer -b NAME`, `set-buffer -b NAME -n NEW` | below 3.4 | A name that does not exist acts on the newest buffer, silently. |
| `split-window -p` | 3.4 | Tmux answers with an error and nothing changes. |
| `:` or `.` in a session or window name | exactly 3.7 | Tmux answers with an error and nothing changes. |

On exact tmux 3.7 a raw `break-pane` is refused, with or without `-n`; use
`Pane#break_out`. Name every nested or key-bound `break-pane` with `-n`,
including the one inside `if-shell` or `run-shell -C` and the default `prefix !`
binding, or upgrade to 3.7a. Exact 3.7 ignores the `-n` name and gives the
window its default name, so `-n` only avoids the crash. Callers must not nest
any other command that a gate refuses. Shell programs given to `run-shell` are
not read either. The library promises no captured `run-shell` stdout: raw output
is what the client prints, and control event routing of `run-shell` output
differs by release.

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

Typed arguments preserve literal semicolons and distinguish pane text from key
names. Hook commands, display formats, pipe shell commands and `source_file`
configuration are explicit executable inputs.

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
successful read. Global session/window/pane listings deduplicate IDs and sort
by numeric ID; scoped listings retain tmux's order. Reads can race with
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
saved layouts beginning with four hexadecimal checksum digits and a comma. On
tmux 3.8 or newer it also accepts JSON layouts beginning with `{`; older
servers raise `UnsupportedFeatureError`.
Unknown or ambiguous names and malformed headers raise `ArgumentError` before
mutation; tmux validates the remaining checksum and geometry. Mirrored names
require tmux 3.5+, otherwise raising `UnsupportedFeatureError`. Name resolution
uses the binding's captured daemon release.

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

Link selection, unlinking, movement, swapping and display check the complete
link identity in the same tmux queue turn as their operation. They avoid
configured command aliases by using unshadowed builtin spellings, and hook
waits before dispatch cannot turn a stale link into its replacement.
Concurrent rewriting of command aliases is outside this guarantee, so
applications must coordinate configuration changes.

## Pane input and capture

`send_text` sends literal text without interpreting key names; `send_keys`
uses native key names. Successful dispatch does not establish shell
completion. `capture` returns raw command evidence and defaults to the
visible screen with all capture flags false. Start/end may be integers or
`"-"`; alternate, mode-screen and pending capture modes are mutually
exclusive. Version-dependent flags are checked before dispatch.

`capture` can join wrapped lines, include attribute escapes, escape nonprintable
bytes, preserve trailing spaces and trim unused trailing cells.
`mode_screen: true` reads the mode's backing screen, which is the copy-mode
snapshot without its UI. `alternate: true` reads tmux's saved screen and raises
when it is absent; while an application occupies the alternate screen, this is
the saved main screen. `pending: true` reads an incomplete escape sequence.
Mode-screen and trailing-cell flags are checked against the daemon's advertised
command usage, and unsupported requests raise explicitly. Command results and
binary buffers preserve trailing newlines.

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
Copy-mode flags are checked against the connected daemon's advertised command
usage.

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

The stable tmux option listing uses its escaped representation, including
octal bytes, and does not split raw values on line breaks. Option names that
contain whitespace are rejected. Indexed `get` acquires the array and selects
locally, so a missing index raises `NoMatchError` while a present empty value
remains present. Append follows tmux's lowest-free-index rule, and indexed
hooks execute in index order. Empty arrays remain distinct from empty String
values.

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

Control connections require tmux 3.7 or newer and are refused earlier on the
checked release (see [Optional tmux features](#optional-tmux-features)).
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

To reconnect, close the old connection, then call
`Server#open_control(session: ref, reconnect: old_connection)` on the same
binding and session. The replacement has a new `generation` and retains
`previous_generation`. Every new subscription begins with a `:reconnect` gap
that names both generations and an unknown loss count. Old subscriptions stay
closed, and requests are never replayed. Event sequences describe one
connection's observations, not durable pane history.

## Control evidence

`GuardedBlock` preserves opening/body/closing bytes and guard identifiers.
`guard_success?` describes `%end` versus `%error`, not shell completion.
`GuardedReply` contains blocks within request boundaries and reports
`attribution: :boundary_window`; unsolicited hooks can share that interval.
It intentionally has no command-result success predicate.

Native `run-shell` output routing depends on tmux: 3.3a–3.4 writes it into
pane view mode; 3.5+ can emit it outside reply blocks as events.
The adapter preserves this behavior. Shell output resembling an unmatched
control terminator fails the connection closed when it reaches the raw stream.
Guarded notification-looking text stays in its reply body.

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

A pause or resume gap event identifies `:pause_requested` or
`:resume_requested` when no outside-block native notice was observed, including
cancellation after possible dispatch. Native notices use `:pause` and
`:resume`. Loss counts are unknown (`dropped_bytes: nil`), and resume does not
replay skipped output.

## Async scope

`Async.open` requires an existing core server and a live caller-owned Async
parent task. It yields a scope and closes its tasks/clients on exit while
preserving the borrowed core server. Scope construction defaults to four
active requests, 32 admitted requests and four controls. Byte and cleanup
limits are explicit constructor keywords. Queued requests count against
capacity and deadline budgets.

Omitting `parent:` uses the existing current Async task. The source server must
outlive the scope, and references keep their source binding identity. A scope
rejects use from another thread, process or scheduler; create a separate scope
for each scheduler thread.

`scope.server` creates scheduler-bound handles through the Async facade.
Inherited operations share core targeting and result contracts but yield on
this scheduler. Using facades/streams on another scheduler, thread or process
raises `ClosedError`. Closing the facade closes its scope. Incomplete cleanup
is reported; repeated successful close is harmless.

`scope.server.run` returns the same binary `CommandResult` as the core. Scheduler
tasks own its stdin, stdout and stderr, and a bounded native helper observes and
reaps each child only after its final signalling handoff. Cancelling the
calling task retires its client and raises `Cancelled` with `:not_sent` or
`:possibly_sent` delivery. An already observed exit completes its bounded
drain. Repeated cancellation does not restart cleanup deadlines or replace an
earlier operation failure, and deadlines cannot undo tmux effects.

An `exchange` on an Async control connection returns guarded blocks with
`:boundary_window` attribution and makes no claim of final command completion.
Outside-block events arrive through `events.next` or an explicit `subscribe`,
and consumer callbacks run outside the parser. Cancelling a dispatched,
undrained exchange closes that connection. A replacement from `reconnect:` stays
owned by the scope and reports a new generation plus a gap with unknown loss.

## Async map

`Scope#map` requires a block, limits concurrent tasks, and returns results in
input order. Defaults use the scope concurrency, at most 1024 items, and the
scope output-byte limit. Results count against retained bytes before return;
a custom `result_bytes` callable supports application values. Failure or
caller cancellation stops sibling work and retires owned clients. Empty
input returns an empty array; unbounded input cannot bypass item/byte limits.

Payload accounting covers strings, primitive values, `CommandResult`, Arrays
and Hashes, and cycles and excessive nesting are refused. A `result_bytes`
callable returns a nonnegative Integer for an application-defined result. Keep
measured values unchanged until the map returns. The payload limits complement
item counts and are not exact Ruby heap measurements.

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

Screen observation requires an empty effective capture hook. On tmux 3.3a–3.4,
applications must coordinate hook configuration changes with captures and
screen waits because sparse-array inspection is a separate preflight.
tmux 3.5+ retains the hook check in the capture queue. Removing the selected
session link refuses the operation on all versions; it cannot select another
session's hook context.

A `tmux_wait` on `screen_contains` joins wrapped rows, so a match that tmux
wrapped across rows is found on the control path from 3.7 and on the polling
path before it. If the pane process, or the tmux server holding it, ends first,
the call fails with code `pane_died` and `delivery: observed`. Its
`error.capture` holds the last rows read, in the shape of a successful capture.
`pane_died` differs from `stale_target`, which means the reference matches no
live entity. When the control stream ends or a read fails, the call asks the daemon one
hook-free question (the `run-shell -C` marker probe). A daemon that does not
answer, including one that a stopped client keeps alive while it shuts down, or
a pane that is gone, is `pane_died`. If the daemon answers and the pane lives,
such as after a detach, the code is `observation_lost`; the polling path holds no
stream to lose.

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

The declared subset has effective version 1. Optional `profile` and `version`
must appear together as `libtmux-ruby.workspace` and `1`. The root accepts
`session_name`, a nonempty `windows` list, `options` and `window_options`. A
window accepts `window_name`, a nonempty `panes` list, `window_index`, `focus`,
`layout` and `options`. Window indexes are unique nonnegative integers;
unspecified indexes use the lowest available value starting at the declared
`base-index` or zero. A pane is a command string or a mapping with `focus`,
`split` and `size`. Split is `horizontal` or `vertical`. Size is a positive
cell count or `1%` through `99%`; neither applies to the initial pane, and
explicit sizes cannot accompany a final named layout.

Root, window and pane mappings accept `start_directory`, `environment`,
`shell_command` and `shell_command_before`. Environment maps merge from parent
to child. Commands inherit unless overridden, and before-commands append in
parent-to-child order. Command values accept a string or an array of strings.
At most one window and one pane per window can declare focus; each defaults to
the first. Layouts are `even-horizontal`, `even-vertical`, `main-horizontal`,
`main-vertical` and `tiled`. Unknown fields and unsupported features fail with
a `ConfigError` that identifies their configuration position.

Session options accept the booleans `status`, `mouse` and `renumber-windows`;
the nonnegative integers `base-index`, `history-limit` and `status-interval`;
and the enumerated `status-position` and `status-justify`. Window options
accept the booleans `automatic-rename`, `allow-rename`, `remain-on-exit`,
`synchronize-panes` and `aggressive-resize`; the nonnegative integers
`pane-base-index`, `main-pane-width` and `main-pane-height`; the text options
`window-status-format` and `window-status-current-format`; and the enumerated
`pane-border-status`. Option text remains tmux option text, including any
formats that tmux evaluates. `pane-base-index` cannot exceed 65535, and the
other numeric options accept integers through 2147483647.

YAML tags, anchors, aliases, duplicate keys, multiple documents and complex
mapping keys are rejected, and so are duplicate JSON keys. The corresponding
`max_*` parse and load keywords adjust the positive limits. Configuration files
must be regular files. With expansion on, only the supplied bounded mapping is
consulted. Shell text and option values are unchanged, `~` has no special path
meaning, and a missing variable fails validation. Parsing checks path syntax,
and apply checks current accessibility; concurrent filesystem changes can still
trigger tmux's cwd fallback.

## Workspace plans

`plan(snapshot: nil)` and `Plan.new` create immutable ordered steps without
tmux I/O. An optional snapshot adds binding/conflict preconditions but is
not a promise that future state will match. Steps retain explicit operation,
arguments, produced symbolic IDs and effect category. Plan/step accessors,
Data constructors, `members` and exports are local. Exports can contain
commands and normalized paths; inspection summarizes without printing them.
No planning method implicitly applies the plan.

A plan creates a new session. It does not reconcile, replace or remove a
preexisting workspace, and the first window and pane from each creation command
are reused.

## Workspace apply

`Plan#apply` explicitly authorizes authored configuration commands. It
requires an existing core server and defaults to a five-second total
deadline, `cancel: nil`, and `compensate: false`. It checks binding/conflicts,
then executes ordered individually attributable operations. Shell command
sending is recorded as dispatch only, not program completion.

Apply is synchronous and uses one monotonic timeout across its core operations.
Panes run `/bin/sh`, and explicit initial-pane environment overrides do not
modify the session environment. Window indexes, splits, options, layout and
focus follow the plan's order. Temporary local option overrides disable
renumbering and pane synchronization during setup, and the plan then restores
declared values or inheritance. Shell commands are sent as literal text
followed by Enter. Both insertion and Enter are dispatch effects, so embedded
newlines can execute during text insertion. Success proves that tmux accepted
the dispatch, not that a shell command finished or succeeded, and shell
commands can leave effects beyond tmux.

Session options precede subsequent window/pane creation. On tmux 3.3a–3.6,
the reused initial pane keeps the global history limit inherited at creation;
later panes use the configured session value. Tmux 3.7+ updates existing grids
when `history-limit` changes. Apply preserves global options and initial IDs.
For uniform history on those versions, configure the server's global value
before applying the workspace.

Creation receipts populate a ledger only with positively returned IDs.
Failure raises `ApplyError` carrying completed steps, known creations,
failed action and uncertainty. Opt-in compensation removes only positively
created objects, guarded against newly linked/joined borrowed members; an
unproven cleanup is refused. Compensation cannot undo shell effects or
unknown dispatched creations and has its own bounded cleanup allowance.

The cleanup allowance is 0.5 seconds. The default preserves partial state for
inspection. Applying or compensating does not close the supplied server
binding. Lost creation replies stay uncertain, and names are never used to
guess ownership. Diagnostics omit command payloads and paths.

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

Without a filename, discovery requires exactly one `.tmuxp.yaml`,
`.tmuxp.yml` or `.tmuxp.json` in the current directory. `--attach` runs an owned
terminal client on the CLI's `/dev/tty` until you detach, and requires a valid
`TERM`. A missing client, or a failure to open or attach the terminal, keeps
the created session and the apply ledger and returns status three.

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

## Typed command coverage

Typed command coverage includes hierarchy creation and listing; rename, split,
resize, swap, join, break, respawn and layout operations; link operations;
options, hooks and environment; capture, send, paste, pipe and buffers; copy
commands; and display, source-file and wait-for. It does not establish complete
flag parity or every compatibility cell; consult the compatibility workflow
results. Executable recipes run against installed artifacts, and the
documentation gate renders YARD and the guides and checks local destinations
and fragments.

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
