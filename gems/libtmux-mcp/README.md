# libtmux-mcp

Expose an existing tmux server over MCP stdio. Read snapshots, capture pane
output, wait for events, or explicitly enable creation, input and shell commands.
The official MCP SDK handles the protocol; bounded Async tasks handle transport.

**Unreleased.** [Build the gems locally](../../README.md#gems) before using the
installed `libtmux-mcp` executable.

## Start the server

Set `TMUX_SOCKET` to an existing tmux socket. This command borrows that daemon
and serves MCP on stdin/stdout:

```console
$ libtmux-mcp \
    --socket "$TMUX_SOCKET" \
    --endpoint local
```

Use `--socket-name NAME` instead of `--socket PATH` to select a named socket.
`--endpoint` sets the public alias used in discovery and resource URIs; it does
not select the socket. EOF retires owned clients and preserves the daemon.

| Tools | Default | Purpose |
| --- | --- | --- |
| `tmux_capabilities`, `tmux_snapshot` | Enabled | Discover capabilities and query captured metadata |
| `tmux_capture`, `tmux_wait` | Disabled | Capture a screen or wait for text/process exit |
| `tmux_create`, `tmux_send`, `tmux_close` | Disabled | Create entities, send text/keys and tear down exact targets |
| `tmux_run` | Disabled | Run a script in an explicitly enrolled zsh shell |

Repeat `--enable-tool` for each additional tool. For screen capture and waits:

```console
$ libtmux-mcp \
    --socket "$TMUX_SOCKET" \
    --enable-tool tmux_capture \
    --enable-tool tmux_wait
```

Disabled tools are absent from discovery and denied on direct application calls.
The [complete protocol recipe](../../examples/mcp_protocol.rb) exercises
discovery, snapshots, default denial, enabled mutations, cancellation and EOF
cleanup through actual pipes, including the installed executable.

## Snapshots, capture and waits

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

Capture refuses nonempty effective `after-capture-pane` hooks, including
inherited sparse entries. On tmux 3.2a–3.4, callers must keep capture-hook
configuration stable throughout observation: those versions require a separate
hook preflight. tmux 3.5+ checks the hook in the capture command queue. Both paths
retain an explicit session/pane context and refuse its removal instead of
switching to another session's hooks. Process tracking retains its native
identity checks on every version that supports it.

`tmux_wait` observes screen text or process exit through events. Canceling it
retires its observation resources without signaling the pane program. Strong
process tracking requires tmux 3.3 or later and a native identity backend:
Linux peer pidfds with matching process namespaces, or Darwin kqueue process
observation. Acquisition verifies the live daemon and pane before retaining
a cursor; unavailable evidence produces an explicit refusal. The
[compatibility workflow](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml)
records each exact platform/version result, including the required tmux 3.2a
refusal and positive identity cases on later versions.

Resource templates expose metadata pages and pane screens under encoded
endpoint/generation URIs. They enforce the same policy and response limits as
their tools. Metadata pages preserve capture identity; screen resources
include interval, truncation and history-continuity metadata. Resource
subscriptions are not advertised.

## Create, send and close

Add `--enable-tool tmux_create`, `--enable-tool tmux_send` or
`--enable-tool tmux_close` to authorize those tools. Creation accepts argument
arrays; sending text and sending named keys are separate variants. Mutation
results contain delivery evidence and positively returned references.
`dispatch_only` input results do not claim program completion, and unknown
effects remain unknown after cancellation.

## Run authored commands

`tmux_run` requires separate policy and shell enrollment. Add
`--enable-tool tmux_run --enroll-pane %ID=FILE` for each exact pane, then
explicitly source the generated file in that pane's interactive zsh 5.9.
The CLI creates a private setup file and never types into the terminal.
It refuses existing files and symlinks. Invitations expire after 60 seconds;
`--enrollment-timeout` accepts at most 300 seconds. At most eight panes may be
enrolled. EOF retires pending enrollment and removes only files the CLI owns.

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
The Linux and macOS compatibility jobs exercise enrollment and the installed
helper dependency closure; consult their results for the revision being used.

## Embed in Ruby

Require `libtmux/mcp`; imports start no tmux process, scheduler or MCP server.
`Application` borrows an application-owned `LibTmux::Async::Server`. Its
`sdk_server` supplies the SDK server consumed by `StdioTransport`. Both objects
stay on that application's reactor thread. See the
[execution guide](../../docs/modes.md) for result and ownership boundaries.

For shell enrollment, call `Application#invite_shell(reference, timeout:,
expires_in:)` and pass the returned invitation to `accept_shell`. The invitation
exposes an immutable `shell_arguments` array for an explicitly sourced setup
command and a monotonic `expires_at`. Its acquisition deadline is separate from
its enrollment lifetime. The application owns invitations and accepted
connections until `close`; direct enrollment calls enforce tool policy.
