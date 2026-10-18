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
output and wait for events, or enable creation, input and shell commands one
tool at a time.

[API reference](https://libtmux.org/en/ruby/latest/mcp/reference/) ·
[Tools](https://libtmux.org/en/ruby/latest/mcp/tools/) ·
[Guides](https://libtmux.org/en/ruby/latest/mcp/guides/) ·
[RubyGems](https://rubygems.org/gems/libtmux-mcp)

</div>

Part of [libtmux for Ruby](https://github.com/libtmux/libtmux-ruby#readme).
Built on [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux)
and [libtmux-async](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux-async).

An MCP client starts `libtmux-mcp` and talks to it over stdin and stdout. The
official MCP SDK handles the protocol, and bounded Async tasks handle
transport.

**Contents** — [Quick start](#quick-start) ·
[Connect a client](#connect-a-client) ·
[Choose the server](#choose-which-tmux-server-it-serves) ·
[The tools](#the-tools) · [Read](#read-the-layout-and-the-screen) ·
[Create](#create-type-and-close) · [Run](#run-a-script-in-a-pane) ·
[Embed](#embed-it-in-ruby) · [Leaves out](#what-it-leaves-out) ·
[Support](#support-and-status) · [Documentation](#documentation)

## Quick start

Install the alpha and its `libtmux-mcp` executable. It needs Ruby 3.3 or newer
and tmux 3.3a or newer:

```console
$ gem install libtmux-mcp --pre
```

The server borrows a tmux server that is already running. Start one on a
socket of its own:

```console
$ tmux -L agent new-session -d -s work
```

Add the server to Claude Code. Until you enable more tools, it serves
[`tmux_capabilities`][tool-tmux_capabilities] and
[`tmux_snapshot`][tool-tmux_snapshot]:

```console
$ claude mcp add tmux -- libtmux-mcp --socket-name agent --endpoint dev
```

Run by hand, `libtmux-mcp` waits for input until EOF. `libtmux-mcp --help`
lists every option.

## Connect a client

### `claude mcp add`: Claude Code

The command in the quick start registers the server with Claude Code. Start the
tmux server first, as above.

### `codex mcp add`: Codex CLI

Codex CLI takes the same command after `--`:

```console
$ codex mcp add tmux -- libtmux-mcp --socket-name agent --endpoint dev
```

### `mcpServers`: clients that read JSON

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

## Choose which tmux server it serves

### `--socket` and `--socket-name`: pick the daemon

Set `TMUX_SOCKET` to an existing tmux socket. This command borrows that daemon
and serves MCP on stdin and stdout:

```console
$ libtmux-mcp \
    --socket "$TMUX_SOCKET" \
    --endpoint local
```

Use `--socket-name NAME` instead of `--socket PATH` to select a named socket,
as the quick start does:

```console
$ libtmux-mcp \
    --socket-name agent
```

- EOF retires the clients the server owns and leaves the daemon running.
- `--endpoint` sets the public alias in discovery and resource URIs, and
  defaults to `local`.

## The tools

Each tool name links to its page on libtmux.org, with the arguments, limits and
result schema. Repeat `--enable-tool` for each additional tool.

| Tools | Default | Purpose |
| --- | --- | --- |
| [`tmux_capabilities`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capabilities/), [`tmux_snapshot`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_snapshot/) | Enabled | Discover capabilities and query captured metadata |
| [`tmux_capture`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capture/), [`tmux_wait`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_wait/) | Disabled | Capture a screen or wait for text/process exit |
| [`tmux_create`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_create/), [`tmux_send`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_send/), [`tmux_close`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_close/) | Disabled | Create entities, send text/keys and tear down exact targets |
| [`tmux_run`](https://libtmux.org/en/ruby/latest/mcp/tools/tmux_run/) | Disabled | Run a script in an explicitly enrolled zsh shell |

- Disabled tools are absent from discovery and denied on direct application
  calls.
- An unknown tool name is refused when the server starts.

The [complete protocol recipe](../../examples/mcp_protocol.rb) exercises
discovery, snapshots, default denial, enabled mutations, cancellation and EOF
cleanup through actual pipes, including the installed executable.

## Read the layout and the screen

### [`tmux_snapshot`][tool-tmux_snapshot]: the layout, in pages

- Pages come from one immutable capture, and a cursor continues that capture.
- An expired, evicted or foreign cursor returns an error. The server never
  substitutes a fresh listing.

### [`tmux_capture`][tool-tmux_capture]: a pane's screen

Enable the screen tools together:

```console
$ libtmux-mcp \
    --socket "$TMUX_SOCKET" \
    --enable-tool tmux_capture \
    --enable-tool tmux_wait
```

- It reads a bounded screen and keeps its line endings. Bytes that are not
  valid UTF-8 come back base64-encoded.
- With tracking, a call returns a cursor, and later calls return a splice
  against that exact captured state. A cursor from another server generation
  or from a respawned pane is refused.
- It refuses a pane whose effective `after-capture-pane` hook is not empty,
  including inherited entries.
- On tmux 3.3a to 3.4 the hook is checked before the capture command runs, so
  keep hook configuration stable while observing.

### [`tmux_wait`][tool-tmux_wait]: wait for text or exit, without polling

- It watches for screen text, or for the pane process to exit, through events.
- A cancelled or expired wait closes its observers and never signals the pane
  program.
- Process tracking needs a native identity backend: Linux peer pidfds with
  matching PID namespaces, or Darwin kqueue. Without one, the call is refused.

### [Resource templates][mcp-resources]: the same data as URIs

[`tmux_metadata`][resource-tmux_metadata],
[`tmux_metadata_page`][resource-tmux_metadata_page] and
[`tmux_screen`][resource-tmux_screen] expose metadata pages and pane screens
under endpoint and generation URIs, with the same policy and limits as their
tools.

- The server does not advertise resource subscriptions.
- [Snapshots, cursors and references][mcp-snapshots-topic] has the full
  contract.

## Create, type and close

### [`tmux_create`][tool-tmux_create]: new sessions, windows and panes

Enable the three tools together:

```console
$ libtmux-mcp \
    --socket-name agent \
    --enable-tool tmux_create \
    --enable-tool tmux_send \
    --enable-tool tmux_close
```

- It takes argument arrays as `argv`.
- Results carry the references tmux returned.

### [`tmux_send`][tool-tmux_send]: literal text or named keys

- Text and keys are separate variants.
- It reports `dispatch_only`: the input was dispatched, and the command has not
  necessarily finished.
- After a cancellation, the effect stays unknown and is not reported as none.

### [`tmux_close`][tool-tmux_close]: an exact target

- It takes an exact session, window or pane reference, and never selects by
  name.

## Run a script in a pane

### [`tmux_run`][tool-tmux_run]: authored commands in an enrolled zsh

[`tmux_run`][tool-tmux_run] runs a POSIX script in a pane's interactive zsh
5.9. It needs both the tool and an enrolled pane.

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
  an error with completion unobserved, and never a truncated success.
- Cancelling a run does not prove that its child processes stopped.

## Embed it in Ruby

Require `libtmux/mcp`. Imports start no tmux process, scheduler or MCP server.
The [execution guide](../../docs/modes.md) covers result and ownership
boundaries.

### [`LibTmux::MCP::Application`][mcp-application]: serve from your own program

[`Application`][mcp-application] borrows an application-owned
[`LibTmux::Async::Server`][async-server]. Its
[`sdk_server`][mcp-application-sdk_server] supplies the SDK server that
[`StdioTransport`][mcp-stdiotransport] consumes:

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

The [complete program](../../examples/mcp_protocol.rb) runs this excerpt inside
an Async task with an open [`LibTmux::Async`][async] scope. It sends real
JSON-RPC messages through the pipes, checks the replies, and prints
`PASS mcp_protocol`.

### [`Application#invite_shell`][mcp-application-invite_shell]: enroll a shell from Ruby

Call `invite_shell` with a pane reference, `timeout:` and `expires_in:`, then
pass the invitation to [`accept_shell`][mcp-application-accept_shell].

- The invitation's `shell_arguments` make up the setup command to source in
  that pane's zsh.
- `timeout:` bounds acquisition, and `expires_in:` sets the enrollment
  lifetime.
- The application owns invitations and accepted connections until
  [`close`][mcp-application-close]. Direct enrollment calls enforce tool
  policy.

## What it leaves out

- **Tools you have not enabled.** Disabled tools are absent from discovery,
  and a direct application call is denied. See [The tools](#the-tools).
- **Resource subscriptions.** The server does not advertise them. See the
  [resource templates][mcp-resources].
- **Typing into your terminal.** The server writes a private setup file and
  never types into a pane's terminal to enroll it. See
  [`tmux_run`][tool-tmux_run].
- **A guaranteed stop.** Cancelling a run does not prove that its child
  processes stopped. See [`tmux_run`][tool-tmux_run].

## Support and status

**Alpha.** APIs may change between releases.

- **Ruby 3.3 or newer.** The gem depends on `libtmux` and `libtmux-async` at
  the same version, the `mcp` SDK 1.5, `digest` and `optparse`.
- **tmux 3.3a or newer.** The server refuses an older daemon when it starts,
  before it serves any tool, and prints the reason and the remedy on stderr.
- **A daemon that changes while it runs.** A tool call returns an
  `unsupported` result with `delivery: not_sent`. The result names the floor
  and says to upgrade tmux and restart the server.
- **Linux, including WSL, and macOS.** The core
  [compatibility workflow][compat] runs Ruby 3.3, 3.4 and 4.0 with tmux 3.3a
  through 3.8 on Ubuntu 24.04. macOS is supported on a best-effort basis, and
  CI coverage for it is highly limited.

## Documentation

| | |
| --- | --- |
| [Reference](https://libtmux.org/en/ruby/latest/mcp/reference/) | The embedding types and methods |
| [Tools](https://libtmux.org/en/ruby/latest/mcp/tools/) | One page per tool, with arguments, limits and result schema |
| [Guides][mcp-guides] | Connect a client to a private tmux server and select its tools |
| [Resources][mcp-resources] | Metadata pages and pane screens as URIs |
| [Public behavior][behavior-mcp-application] | The application, transport and command |

[async]: https://libtmux.org/en/ruby/latest/reference/libtmux-async/
[async-server]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-server/
[behavior-mcp-application]: ../../docs/reference/behavior.md#mcp-application
[compat]: https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml
[mcp-application]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application/
[mcp-application-accept_shell]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application-accept_shell/
[mcp-application-close]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application-close/
[mcp-application-invite_shell]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application-invite_shell/
[mcp-application-sdk_server]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-application-sdk_server/
[mcp-guides]: https://libtmux.org/en/ruby/latest/mcp/guides/
[mcp-resources]: https://libtmux.org/en/ruby/latest/mcp/resources/
[mcp-snapshots-topic]: https://libtmux.org/en/ruby/latest/mcp/topics/snapshots-and-references/
[mcp-stdiotransport]: https://libtmux.org/en/ruby/latest/mcp/reference/libtmux-mcp-stdiotransport/
[resource-tmux_metadata]: https://libtmux.org/en/ruby/latest/mcp/resources/templates/tmux_metadata/
[resource-tmux_metadata_page]: https://libtmux.org/en/ruby/latest/mcp/resources/templates/tmux_metadata_page/
[resource-tmux_screen]: https://libtmux.org/en/ruby/latest/mcp/resources/templates/tmux_screen/
[tool-tmux_capabilities]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capabilities/
[tool-tmux_capture]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_capture/
[tool-tmux_close]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_close/
[tool-tmux_create]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_create/
[tool-tmux_run]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_run/
[tool-tmux_send]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_send/
[tool-tmux_snapshot]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_snapshot/
[tool-tmux_wait]: https://libtmux.org/en/ruby/latest/mcp/tools/tmux_wait/
