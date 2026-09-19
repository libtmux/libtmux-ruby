# libtmux

Ruby tmux orchestration core, under development. `Server.open` borrows an
existing explicit endpoint. Closing it retires owned clients and preserves
the daemon; `kill` explicitly terminates the daemon. `Server.start` creates a
private owned foreground daemon whose lifetime ends with its server handle.
Owned startup currently has Linux evidence; other platform cells remain open.

Require `libtmux` after installing the locally built gem. Imports do not
start tmux, a scheduler or an MCP server. See the repository's contribution
guide for local build and verification commands.

Handles carry immutable refs bound to one open server binding. IDs and refs
are local readers; `list_*`, `snapshot` and command methods perform explicit
I/O. Global windows represent unique entities. `WindowLink` retains a session,
index and window ID so repeated links stay distinct.

Link selection, unlinking, movement, swapping and display check the complete
link identity in the same tmux queue turn as their operation. Configured
command aliases are avoided using unshadowed builtin spellings. Hook waits
before dispatch cannot turn a stale link into its replacement. Concurrent
rewriting of command aliases is outside this guarantee; applications must
coordinate configuration changes. This has local Linux/tmux evidence only.

Typed arguments preserve literal semicolons and distinguish pane text from
key names. Pane commands take executable argument arrays. Hook commands,
display formats, pipe shell commands and `source_file` configuration are
explicit executable inputs. `Server.run` remains the raw tmux escape hatch,
including daemon aliases, separators and format semantics.

Creation accepts `cwd:` and a String-to-String `environment:` map. Directories
resolve from the Ruby caller and are checked before dispatch; concurrent
filesystem changes can still trigger tmux's directory fallback. Creation
returns tmux-assigned IDs after dispatch, without claiming program readiness
or a successful program exit. `new_session(window_name:)` names the initial
window; its index can be moved explicitly after creation. `new_window(index:)`
refuses an occupied slot. `Pane#split` targets that exact pane, with `size:` as
cells or a percentage string. Windows and splits retain focus unless
`focus: true` is requested.

Typed operations accept `timeout:` and `cancel:`. Composed link and copy operations
share one deadline across their preflights and final dispatch. Copy-mode
exit uses `cancel_mode: true`; `cancel:` always means a cancellation token.

`Options` retains raw bytes, inheritance and sparse array indexes;
`OptionValue#as` requests a strict conversion. Hook values remain tmux command
strings. The stable tmux option listing uses its escaped representation,
including octal bytes; it does not split raw values on line breaks. Option
names containing whitespace are currently rejected. Inherited hook listing
is not implemented and raises explicitly.

Indexed `get` acquires the array and selects locally, so a missing index raises
`NoMatchError` while a present empty value remains present. Reading an array
without an index raises `MultipleMatchesError` when it has several entries.
Append follows tmux's lowest-free-index rule; indexed hooks execute in index
order. Empty arrays remain distinct from empty String values.

Binary buffers and command results preserve trailing newlines. Capture can
join wrapped lines, include attribute escapes, escape nonprintable bytes,
preserve trailing spaces and trim unused trailing cells. `mode_screen: true`
reads the mode's backing screen (the copy-mode snapshot, without its UI),
`alternate: true` reads tmux's saved screen and raises when absent (while an
application occupies the alternate screen, this is the saved main screen),
and `pending: true` reads an incomplete escape sequence. These three selectors
are mutually exclusive. Mode-screen and trailing-cell flags are checked
against advertised command usage; unsupported requests raise explicitly.
Copy-mode flags are checked against the connected daemon's advertised command
usage. Client discovery returns observations. `Server#attach` uses an explicit
caller-owned TTY and terminal type, waits for its owned client to exit, and
restores the terminal mode. Exact borrowed-client targeting and switching
remain open work.

Control connections expose bounded event subscriptions and raw guarded replies.
`pause_output(pane_id:)` and `resume_output(pane_id:)` return `GuardedReply`;
they do not establish that an action took effect. Their gap events identify
`:pause_requested` or `:resume_requested` when no outside-block native notice
was observed, including cancellation after possible dispatch. Native notices
use `:pause` and `:resume`. Loss counts are unknown (`dropped_bytes: nil`);
resume does not replay skipped output. Guarded notification-looking text stays
in its reply body.

Close the old control connection, then explicitly call
`server.open_control(session: ref, reconnect: old_connection)` to reconnect
within the same binding and session. The replacement has a new `generation`
and retains `previous_generation`. Every new subscription begins with a
`:reconnect` gap containing both generations and an unknown loss count. Old
subscriptions stay closed, and requests are never replayed. Event sequences
describe one connection's observations, not durable pane history.

The current typed command slice covers hierarchy creation/listing,
rename/split/resize/swap/join/break/respawn/layout operations, link operations,
options/hooks/environment, capture/send/paste/pipe/buffers, copy commands,
display/source-file/wait-for. It does not establish complete flag parity or
the proposed tmux/Ruby/platform matrix. RBS validation checks declarations,
not implementation typing. [Executable recipes](../../docs/recipes.md) run
against installed artifacts; the documentation gate renders YARD and guides
and checks local destinations and fragments. Complete behavioral reference
coverage, the full compatibility matrix and release automation remain open.
