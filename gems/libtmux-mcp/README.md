<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Ruby MCP">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux-mcp

Expose an existing tmux server over MCP stdio. Read snapshots, capture pane
output, wait for events, or explicitly enable creation, input and shell commands.
The official MCP SDK handles the protocol; bounded Async tasks handle transport.

[API reference](https://libtmux.org/en/ruby/latest/mcp/reference/) ·
[Tools](https://libtmux.org/en/ruby/latest/mcp/tools/) ·
[Guides](https://libtmux.org/en/ruby/latest/mcp/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux-mcp)

</div>

**Contents** — [Install](#install) · [Start the server](#start-the-server) ·
[Connect a client](#connect-a-client) ·
[Snapshots, capture and waits](#snapshots-capture-and-waits) ·
[Create, send and close](#create-send-and-close) ·
[Run authored commands](#run-authored-commands) ·
[Embed in Ruby](#embed-in-ruby)

Part of [libtmux for Ruby](https://github.com/libtmux/libtmux-ruby#readme).
Built on [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux)
and [libtmux-async](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-async).

Requires tmux 3.3a or newer.

- The server refuses an older daemon when it starts, before it serves any tool,
  and prints the reason and the remedy on stderr.
- If the daemon changes while the server runs, a tool call returns an
  `unsupported` result with `delivery: not_sent`. The result names the floor
  and says to upgrade tmux and restart the server.

## Install

Install the alpha and its `libtmux-mcp` executable:

```console
$ gem install libtmux-mcp --pre
```

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

To try it, start a tmux server on a socket of its own, then serve it by name:

```console
$ tmux -L agent new-session -d -s work
```

```console
$ libtmux-mcp \
    --socket-name agent
```

An MCP client launches this command and speaks to it on stdin and stdout. Run
by hand, it waits for input until EOF. The alias defaults to `local`, and
`libtmux-mcp --help` lists every option.

| Tools | Default | Purpose |
| --- | --- | --- |
| [`tmux_capabilities`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capabilities/), [`tmux_snapshot`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_snapshot/) | Enabled | Discover capabilities and query captured metadata |
| [`tmux_capture`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capture/), [`tmux_wait`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_wait/) | Disabled | Capture a screen or wait for text/process exit |
| [`tmux_create`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_create/), [`tmux_send`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_send/), [`tmux_close`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_close/) | Disabled | Create entities, send text/keys and tear down exact targets |
| [`tmux_run`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_run/) | Disabled | Run a script in an explicitly enrolled zsh shell |

Each tool name links to its page on libtmux.org, with the arguments, limits and
result schema. Repeat `--enable-tool` for each additional tool. For screen
capture and waits:

```console
$ libtmux-mcp \
    --socket "$TMUX_SOCKET" \
    --enable-tool tmux_capture \
    --enable-tool tmux_wait
```

- Disabled tools are absent from discovery and denied on direct application
  calls.
- An unknown tool name is refused when the server starts.

The [complete protocol recipe](../../examples/mcp_protocol.rb) exercises
discovery, snapshots, default denial, enabled mutations, cancellation and EOF
cleanup through actual pipes, including the installed executable.

## Connect a client

Start a tmux server as above, then give your client the command. Claude Code:

```console
$ claude mcp add tmux -- libtmux-mcp --socket-name agent --endpoint dev
```

Codex CLI:

```console
$ codex mcp add tmux -- libtmux-mcp --socket-name agent --endpoint dev
```

A client that reads a JSON configuration, such as Claude Desktop's
`claude_desktop_config.json`, takes the same command as an `mcpServers` entry:

<!-- example: mcp_client/config -->
```json
{
  "mcpServers": {
    "tmux": {
      "command": "libtmux-mcp",
      "args": ["--socket-name", "agent", "--endpoint", "dev"]
    }
  }
}
```
<!-- /example -->

If the client does not start servers with your shell's `PATH`, set `command` to
the absolute path that `command -v libtmux-mcp` prints.

## Snapshots, capture and waits

[`tmux_snapshot`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_snapshot/):

- Pages come from one immutable capture, and a cursor continues that capture.
- An expired, evicted or foreign cursor returns an error. The server never
  substitutes a fresh listing.

[`tmux_capture`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capture/):

- Reads a bounded screen and keeps its line endings. Bytes that are not valid
  UTF-8 come back base64-encoded.
- With tracking, a call returns a cursor, and later calls return a splice
  against that exact captured state. A cursor from another server generation
  or from a respawned pane is refused.
- Refuses a pane whose effective `after-capture-pane` hook is not empty,
  including inherited entries. On tmux 3.3a to 3.4 the hook is checked before
  the capture command runs, so keep hook configuration stable while observing.

[`tmux_wait`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_wait/):

- Watches for screen text or for the pane process to exit through events. It
  does not poll.
- A cancelled or expired wait closes its observers. It never signals the pane
  program.
- Process tracking needs a native identity backend: Linux peer pidfds with
  matching PID namespaces, or Darwin kqueue. Without one, the call is refused.

Resource templates expose metadata pages and pane screens under endpoint and
generation URIs, with the same policy and limits as their tools. The server
does not advertise resource subscriptions. See
[resources](https://libtmux.org/en/ruby/latest/mcp/resources/) and
[snapshots, cursors and references](https://libtmux.org/en/ruby/latest/mcp/topics/snapshots-and-references/)
for the full contract.

## Create, send and close

Enable the three tools together:

```console
$ libtmux-mcp \
    --socket-name agent \
    --enable-tool tmux_create \
    --enable-tool tmux_send \
    --enable-tool tmux_close
```

- [`tmux_create`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_create/)
  takes argument arrays as `argv`.
- [`tmux_send`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_send/) sends
  literal text or named keys, as separate variants.
- [`tmux_close`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_close/)
  takes an exact session, window or pane reference and never selects by name.
- Results carry the references tmux returned.
  [`tmux_send`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_send/)
  reports `dispatch_only`: the input was dispatched, not run to completion.
- After a cancellation, the effect stays unknown. It is not reported as none.

## Run authored commands

[`tmux_run`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_run/) runs a
POSIX script in a pane's interactive zsh 5.9. It needs both the tool and an
enrolled pane.

List the pane IDs of the server:

```console
$ tmux -L agent list-panes -a -F '#{pane_id}'
```

```text
%0
```

Enable the tool and write a setup file for one exact pane:

```console
$ libtmux-mcp \
    --socket-name agent \
    --enable-tool tmux_run \
    --enroll-pane %0=enroll.zsh
```

Then, in that pane's zsh, run `source enroll.zsh`. A relative path resolves
from the directory where the server starts.

- `--enroll-pane` requires `--enable-tool tmux_run`, and each pane and each
  file may appear once.
- The server writes a private file (mode `0600`) and never types into the
  terminal. It refuses an existing file or a symlink.
- Setup files expire. `--enrollment-timeout SECONDS` sets the lifetime, at most
  300.
- EOF retires pending enrollment and removes only the files the server wrote.
- A call takes an exact pane `target`, a POSIX `script`, and optional
  `stdout_limit` and `stderr_limit` byte counts.
- The script runs with the shell's working directory and exported environment.
- Stdout and stderr come back separately, as UTF-8 or base64.
- A nonzero exit or a signal is a completion result. Output over its limit is
  an error with completion unobserved, never a truncated success.
- Cancelling a run does not prove that its child processes stopped.

## Embed in Ruby

Require `libtmux/mcp`. Imports start no tmux process, scheduler or MCP server.

- [`Application`](https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application/) borrows an application-owned
  [`LibTmux::Async::Server`](https://libtmux.org/en/ruby/latest/reference/libtmux-async-server/).
- Its [`sdk_server`](https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application-sdk_server/) supplies the SDK
  server that [`StdioTransport`](https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-stdiotransport/) consumes.
- The [execution guide](../../docs/modes.md) covers result and ownership
  boundaries.

The [complete program](../../examples/mcp_protocol.rb) runs this excerpt inside
an Async task with an open [`LibTmux::Async`](https://libtmux.org/en/ruby/latest/reference/libtmux-async/) scope.

<!-- example: mcp_protocol/main -->
```ruby
application = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "example")
sdk = application.sdk_server
input, client_input = IO.pipe
client_output, output = IO.pipe
transport = LibTmux::MCP::StdioTransport.new(server: sdk, parent: parent, input: input, output: output)
runner = parent.async { transport.run }
```
<!-- /example -->

To enroll a shell from Ruby, call
[`Application#invite_shell`](https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application-invite_shell/) with a
pane reference, `timeout:` and `expires_in:`, then pass the invitation to
[`accept_shell`](https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application-accept_shell/).

- The invitation's `shell_arguments` make up the setup command to source in
  that pane's zsh.
- `timeout:` bounds acquisition, and `expires_in:` sets the enrollment
  lifetime.
- The application owns invitations and accepted connections until
  [`close`](https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application-close/). Direct enrollment calls
  enforce tool policy.
