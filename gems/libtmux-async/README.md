<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Ruby">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux-async

Run libtmux operations inside an application-owned Async task: a
[subprocess facade][async-server], [ordered mapping][async-scope-map],
[control replies][guardedreply] and
[event subscriptions][async-controlsubscription].

[API reference](https://libtmux.org/en/ruby/latest/reference/libtmux-async/) ·
[Guide](https://libtmux.org/en/ruby/latest/guides/async/) ·
[RubyGems](https://rubygems.org/gems/libtmux-async)

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/ruby/)
[![libtmux-async](https://img.shields.io/gem/v/libtmux-async)](https://rubygems.org/gems/libtmux-async)

</div>

Part of [libtmux for Ruby](https://github.com/libtmux/libtmux-ruby#readme).
Built on [libtmux](https://github.com/libtmux/libtmux-ruby/tree/master/gems/libtmux).

Imports start no scheduler, tmux server or background task. A scope borrows a
core [`Server`][server] and leaves its daemon running when the scope exits.

**Contents** — [Quick start](#quick-start) ·
[Cancel](#cancel-a-request-without-stalling-the-others) ·
[Map](#keep-results-ordered-and-bounded) ·
[Control](#read-control-events-in-a-scope) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status) ·
[Documentation](#documentation)

## Quick start

Install the gem. It needs Ruby 3.3 or newer and tmux 3.3a or newer on
`PATH`:

```console
$ gem install libtmux-async
```

Open a scope over a core server with [`LibTmux::Async.open`][async-open], then
capture every pane concurrently with [`Scope#map`][async-scope-map]. The outer
[`Server.start`][server-start] block only supplies a server for the scope to
borrow:

<!-- example: api_async_scope/main -->
```ruby
require "libtmux"
require "libtmux/async"

LibTmux::Server.start do |server|
  server.new_session(name: "work", command: ["/bin/cat"])
  server.new_session(name: "logs", command: ["/bin/cat"])
  Async do |parent|
    LibTmux::Async.open(parent: parent, server: server) do |scope|
      refs = scope.server.list_panes.map(&:ref)
      screens = scope.map(refs, concurrency: 2) { |ref| scope.server.pane(ref).capture }
      puts "captured panes: #{screens.length}"
      puts "all succeeded: #{screens.all?(&:success?)}"
    end
  end.wait
end
```
<!-- /example -->

It prints:

```text
captured panes: 2
all succeeded: true
```

- Leave out `parent:` to use the current Async task.
- A scope rejects use from another thread, process or scheduler, so create one
  scope for each scheduler thread.
- Scope exit retires its clients and joins its owned tasks.

## Cancel a request without stalling the others

### [`Async::Server#run`][async-server-run]: cancel a request that is waiting

`scope.server.run` waits for a tmux command in a task. Cancel that task and
the scope retires its client, while sibling requests keep running.

[`wait_for`][async-server-wait_for] returns once the request has signalled
that it is running, so the cancel arrives while it waits:

<!-- example: api_async_run/main -->
```ruby
require "libtmux"
require "libtmux/async"

LibTmux::Server.start do |server|
  server.new_session(name: "work", command: ["/bin/cat"])
  Async do |parent|
    LibTmux::Async.open(parent: parent, server: server) do |scope|
      waiting = parent.async do
        scope.server.run(["wait-for", "-S", "ready", ";", "wait-for", "held"], timeout: 5)
      rescue LibTmux::Cancelled => error
        error
      end
      scope.server.wait_for("ready", timeout: 5)
      waiting.cancel
      failure = waiting.wait
      puts "request: #{failure.class}"
      puts "delivery: #{failure.delivery}"
    end
  end.wait
end
```
<!-- /example -->

It prints:

```text
request: LibTmux::Cancelled
delivery: possibly_sent
```

- `run` returns the same binary [`CommandResult`][commandresult] as the core.
- [`Cancelled`][cancelled] carries `delivery` as `:not_sent` or
  `:possibly_sent`. A deadline cannot undo tmux effects.
- Interactive terminal attachment stays on the blocking core and raises
  [`UnsupportedFeatureError`][unsupportedfeatureerror] here.

The [complete program](../../examples/async_cancel.rb) also keeps capturing
while the request waits, and checks that the cancelled client is reaped. The
contract is in [Async scope][behavior-async-scope].

## Keep results ordered and bounded

### [`Scope#map`][async-scope-map]: input order, capped payloads

`map` runs a block for each item, up to `concurrency:` at a time, and returns a
frozen Array in input order. The quick start is a `map`. These limits apply to
every scope:

| Scope limit | Default |
| --- | --- |
| Active subprocess clients | 4 |
| Admitted subprocess requests, including unconsumed results | 32 |
| Queued request payload | 4 MiB |
| Retained process and map output payload | 8 MiB |
| Per-command stdout / stderr | 1 MiB / 256 KiB |
| Control connections | 4 |
| Ordinary command deadline | 5 seconds |

- Independent requests may complete out of order, and the result is still in
  input order.
- `map` caps retained items and counts payload bytes of strings, primitive
  values, [`CommandResult`][commandresult], Arrays and Hashes. Cycles and deep
  nesting are refused.
- An application-defined result needs a `result_bytes:` callable that returns
  a nonnegative Integer.
- Keep measured values unchanged until the map returns. The counts cover
  payload bytes and do not measure the Ruby heap.

The contract is in [Async map][behavior-async-map].

## Read control events in a scope

### [`Async::Server#open_control`][async-server-open_control]: replies and events

A control connection has its own request, reply and subscriber limits.
[`exchange`][async-controlconnection-exchange] runs one command, and
[`events`][async-controlconnection-events] yields what tmux reports outside a
reply:

<!-- example: api_async_control/main -->
```ruby
require "libtmux"
require "libtmux/async"

LibTmux::Server.start do |server|
  session = server.new_session(name: "work", command: ["/bin/cat"])
  window = session.list_windows.fetch(0)
  Async do |parent|
    LibTmux::Async.open(parent: parent, server: server) do |scope|
      scope.server.open_control(session: session.ref) do |control|
        reply = control.exchange("display-message -p ready", timeout: 5)
        puts "reply: #{reply.blocks.last.body.strip}"
        events = control.events
        window.rename("renamed")
        event = events.next(timeout: 5) until event&.raw&.start_with?("%window-renamed")
        puts "event: #{event.raw.strip}"
      end
    end
  end.wait
end
```
<!-- /example -->

It prints:

```text
reply: ready
event: %window-renamed @0 renamed
```

- `exchange` answers a [`GuardedReply`][guardedreply] with `:boundary_window`
  attribution. It makes no claim that the command finished.
- Events arrive through `events.next` or an explicit
  [`subscribe`][async-controlconnection-subscribe]. Consumer callbacks run
  outside the parser.
- A reliable subscription raises on overflow, and a tail subscription reports
  the dropped range.
- Cancelling a dispatched exchange that is not drained closes the connection.
- [`pause_output`][async-controlconnection-pause_output] and
  [`resume_output`][async-controlconnection-resume_output] report possible
  loss through gap events. A gap does not show that the action took effect.
- To reconnect, close the connection and pass it as `reconnect:`. The
  replacement stays owned by the scope, has a new generation, and starts with
  a gap of unknown loss. Nothing is replayed.

The contract is in [Control connections][behavior-control].

## What it leaves out

- **Terminal attachment.** `attach` stays on the blocking core and raises
  [`UnsupportedFeatureError`][unsupportedfeatureerror] on this facade.
- **Replay.** Reconnect and resume never replay requests or missed output. See
  [Control connections][behavior-control].
- **A scheduler.** Imports start no scheduler or background task, and your
  application owns the Async root task. See [Execution modes][doc-modes].
- **Cross-thread scopes.** A scope belongs to the thread, process and
  scheduler that opened it. See [Async scope][behavior-async-scope].

## Support and status

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelog marks each break. Pin an exact version to avoid one.

- **Ruby 3.3 or newer** and **tmux 3.3a or newer.** The facade dispatches
  through a version-checked core server, so it carries the same daemon release
  check.
- **Control connections need tmux 3.7 or newer.**
  [`open_control`][async-server-open_control] refuses an older daemon before a
  control client attaches.
- **Async 2.46.** The gem depends on `async` ~> 2.46.0 and the same version of
  `libtmux`.
- **Linux, including WSL, and macOS.** The [compatibility workflow][compat]
  runs Ruby 3.3, 3.4 and 4.0 with tmux 3.3a through 3.8 on Ubuntu 24.04 and retains
  per-revision results. macOS is supported on a best-effort basis, and CI
  coverage for it is highly limited.

## Documentation

| | |
| --- | --- |
| [Reference](https://libtmux.org/en/ruby/latest/reference/libtmux-async/) | The Async classes, one page each |
| [Async guide](https://libtmux.org/en/ruby/latest/guides/async/) | Running concurrent commands within an owned scope |
| [Execution modes][doc-modes] | Blocking calls, Async tasks and control subscriptions |
| [Recipes][doc-recipes] | Complete programs with checked excerpts |
| [Public behavior][behavior-async-scope] | Scheduling, ownership and limits of a scope |

[async-controlconnection-events]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-controlconnection-events/
[async-controlconnection-exchange]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-controlconnection-exchange/
[async-controlconnection-pause_output]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-controlconnection-pause_output/
[async-controlconnection-resume_output]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-controlconnection-resume_output/
[async-controlconnection-subscribe]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-controlconnection-subscribe/
[async-controlsubscription]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-controlsubscription/
[async-open]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-open/
[async-scope-map]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-scope-map/
[async-server]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-server/
[async-server-open_control]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-server-open_control/
[async-server-run]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-server-run/
[async-server-wait_for]: https://libtmux.org/en/ruby/latest/reference/libtmux-async-server-wait_for/
[behavior-async-map]: ../../docs/reference/behavior.md#async-map
[behavior-async-scope]: ../../docs/reference/behavior.md#async-scope
[behavior-control]: ../../docs/reference/behavior.md#control-connections
[cancelled]: https://libtmux.org/en/ruby/latest/reference/libtmux-cancelled/
[commandresult]: https://libtmux.org/en/ruby/latest/reference/libtmux-commandresult/
[compat]: https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml
[doc-modes]: ../../docs/modes.md
[doc-recipes]: ../../docs/recipes.md
[guardedreply]: https://libtmux.org/en/ruby/latest/reference/libtmux-guardedreply/
[server]: https://libtmux.org/en/ruby/latest/reference/libtmux-server/
[server-start]: https://libtmux.org/en/ruby/latest/reference/libtmux-server-start/
[unsupportedfeatureerror]: https://libtmux.org/en/ruby/latest/reference/libtmux-unsupportedfeatureerror/
