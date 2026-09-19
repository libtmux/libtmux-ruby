# libtmux-mcp

Expose a fixed tmux endpoint through the official MCP SDK and bounded Async
stdio transport. This unreleased package provides capability discovery,
immutable metadata pagination, bounded pane capture and observation, literal
text/key input, session/window/pane creation and guarded teardown. Discovery
and snapshots are enabled by default; other tools require explicit policy.
Authored shell commands through `tmux_run` remain implementation work.

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
process tracking currently requires tmux 3.3 or later, Linux peer pidfds and
matching process namespaces; unsupported platforms refuse explicitly. The
complete platform matrix remains open.

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

The [complete protocol recipe](../../examples/mcp_protocol.rb) runs direct
transport cancellation and the installed executable through actual pipes.
It asserts discovery, snapshot reads, default denial, explicitly enabled
creation/input/teardown, and EOF cleanup. See the
[execution guide](../../docs/modes.md) for result and ownership boundaries.
