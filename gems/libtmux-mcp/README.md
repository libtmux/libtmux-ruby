# libtmux-mcp

Expose a fixed tmux endpoint through the official MCP SDK and bounded Async
stdio transport. This unreleased package provides capability discovery,
immutable metadata pagination, bounded pane capture and observation, literal
text/key input, session/window/pane creation, guarded teardown and authored
commands in explicitly enrolled zsh shells. Discovery
and snapshots are enabled by default; other tools require explicit policy.

Require `libtmux/mcp` after installing the locally built gem. Imports do not
start tmux, a scheduler or an MCP server. See the repository's contribution
guide for local build and verification commands.

`Application` borrows an application-owned `LibTmux::Async::Server`. Its
`sdk_server` supplies the SDK server consumed by `StdioTransport`. Both objects
stay on that application's reactor thread. Disabled tools are absent from
discovery and denied on direct application calls.

Snapshot pages retain one immutable capture and query. Cursor expiry or eviction
returns an error; it never substitutes a new live listing. Defaults retain up to
16 captures and 8 MiB for 30 seconds, with a five-second acquisition deadline and
one-MiB structured response limit. A cursor pages captured metadata; it does not
claim that an old pane process still exists. Schema validation supplements the
core decoder's stricter byte, depth, node and duplicate-key rules.

Opt into `tmux_capture` for a bounded screen snapshot. Results retain line
endings, encode invalid UTF-8 as base64, and distinguish truncated screen
content from unknown history continuity. Tracking produces a retained cursor;
subsequent calls return a splice against that exact captured state. A screen
delta does not establish that every intervening output byte was observed.

`tmux_wait` observes screen text or process exit through events. Canceling it
retires its observation resources without signaling the pane program. Strong
process tracking requires tmux 3.3 or later and a native identity backend:
Linux peer pidfds with matching process namespaces, or Darwin kqueue process
observation. Acquisition verifies the live daemon and pane before retaining
a cursor; unavailable evidence produces an explicit refusal. The exact
macOS/Ruby 4.0.7/tmux 3.7c cell has passed; the complete platform matrix
remains open.

Resource templates expose metadata pages and pane screens under encoded
endpoint/generation URIs. They enforce the same policy and response limits as
their tools. Metadata pages preserve capture identity; screen resources
include interval, truncation and history-continuity metadata. Resource
subscriptions are not advertised.

The installed `libtmux-mcp` executable borrows an explicitly selected daemon:

```console
$ libtmux-mcp \
    --socket "$TMUX_SOCKET" \
    --endpoint local
```

Add `--enable-tool tmux_create`, `--enable-tool tmux_send` or
`--enable-tool tmux_close` to authorize those tools. Creation accepts argument
arrays; sending text and sending named keys are separate variants. Mutation
results contain delivery evidence and positively returned references.
`dispatch_only` input results do not claim program completion, and unknown
effects remain unknown after cancellation. Closing the protocol input retires
its owned clients and preserves the borrowed tmux daemon.

`tmux_run` requires separate policy and shell enrollment. Add
`--enable-tool tmux_run --enroll-pane %ID=FILE` for each exact pane, then
explicitly source the generated file in that pane's interactive zsh 5.9.
The CLI creates a private setup file and never types into the terminal.
It refuses existing files and symlinks. Invitations expire after 60 seconds;
`--enrollment-timeout` accepts at most 300 seconds. At most eight panes may be
enrolled. EOF retires pending enrollment and removes only files the CLI owns.

Embedding callers use `Application#invite_shell(reference, timeout:,
expires_in:)` and pass the returned invitation to `accept_shell`. The invitation
exposes an immutable `shell_arguments` array for an explicitly sourced setup
command and a monotonic `expires_at`. The invitation acquisition deadline is
separate from its enrollment lifetime. The application owns invitations and
accepted connections until `close`; direct enrollment calls enforce tool policy.

The tool accepts an exact pane target, a POSIX `script`, and separate
`stdout_limit`/`stderr_limit` byte counts. Scripts may contain at most 65,536
bytes. Each output defaults to 65,536 bytes and is capped at 262,144; the
application reserves its worst-case serialized response before authorization.
The helper inherits the enrolled shell's cwd and exported environment, uses
closed stdin, and reports separate UTF-8 or base64 outputs. Nonzero exit and
signal termination are completion results. Output overflow is an error with
completion unobserved, not silently truncated success. Shell variables,
functions, options and cwd changes do not persist in the interactive parent.

An idle, empty primary ZLE editor receives the request through a private socket.
A guarded tmux queue operation authorizes one script digest for one retained
server, pane process and enrollment generation. Execution may follow that
authorization; a later respawn does not redirect the prepared helper to its
replacement. Error responses retain known authorization and native completion
receipts. Cancellation does not prove that arbitrary descendants stopped.
Linux enrollment and installed helper closure have local runtime evidence;
Darwin enrollment and the complete version matrix remain open.

The [complete protocol recipe](../../examples/mcp_protocol.rb) runs direct
transport cancellation and the installed executable through actual pipes.
It asserts discovery, snapshot reads, default denial, explicitly enabled
creation/input/teardown, and EOF cleanup. See the
[execution guide](../../docs/modes.md) for result and ownership boundaries.
