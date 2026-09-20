# libtmux-async

Run libtmux operations inside an application-owned Async task. This unreleased
gem provides a subprocess facade, ordered mapping, control replies and event
subscriptions. Imports start no scheduler, tmux server or background task.

The [complete program](../../examples/async_cancel.rb) owns an isolated server
and its cleanup. This excerpt uses that server and creates the Async root:

<!-- example: async_cancel/main -->
```ruby
Async do |parent|
  LibTmux::Async.open(parent: parent, server: server) do |scope|
    waiting = parent.async do
      scope.server.run(["wait-for", "-S", "ready", ";", "wait-for", "held"], timeout: 0.5)
    rescue LibTmux::Cancelled => error
      error
    end
    scope.server.wait_for("ready", timeout: 0.5)
    Example.check(scope.diagnostics.fetch(:active_process_slots) == 1, "waiting client lost its slot")
    captures = scope.map(scope.server.list_panes.map(&:ref), concurrency: 2) do |ref|
      scope.server.pane(ref).capture
    end
    Example.check(captures.all?(&:success?), "sibling captures stalled")
    waiting.cancel
    failure = waiting.wait
    Example.check(failure.is_a?(LibTmux::Cancelled), "cancellation lost")
    Example.check(failure.delivery == :possibly_sent, "cancelled dispatch claimed no effects")
    Example.raises(Errno::ECHILD) { Process.waitpid(failure.pid, Process::WNOHANG) }
    Example.check(scope.server.diagnostics.fetch(:admitted_requests).zero?, "cancelled client remains admitted")
  end
end.wait
```
<!-- /example -->

Omitting `parent:` uses the existing current Async task. The source server must
outlive the scope. References keep their source binding identity. Scope exit
retires its clients and joins its owned tasks; it leaves the borrowed daemon
alive. A scope rejects use from another thread, process or scheduler. Create a
separate scope for each scheduler thread. Interactive terminal attachment stays
on the blocking core facade and raises `UnsupportedFeatureError` on this facade.

`scope.server.run` returns the same binary `CommandResult` as core. Its stdin,
stdout and stderr are owned by scheduler tasks. A bounded native helper observes
and reaps each child only after its final signalling handoff. Cancelling the
calling task retires its client and raises `Cancelled` with `:not_sent` or
`:possibly_sent` delivery. An already observed exit completes its bounded drain.
Repeated cancellation does not restart cleanup deadlines or replace an earlier
operation failure. Deadlines cannot undo tmux effects.

`scope.map` returns a frozen Array in input order; independent requests may
complete out of order. It caps retained items at 1024 and accounts payload bytes
in strings, primitive values, `CommandResult`, Arrays and Hashes. Cycles and
excessive nesting are refused. Application-defined results require an explicit
`result_bytes:` callable returning a nonnegative Integer. Keep measured values
unchanged until the map returns. These payload limits complement item counts;
they are not exact Ruby heap measurements.

| Scope limit | Default |
| --- | --- |
| Active subprocess clients | 4 |
| Admitted subprocess requests, including unconsumed results | 32 |
| Queued request payload | 4 MiB |
| Retained process and map output payload | 8 MiB |
| Per-command stdout / stderr | 1 MiB / 256 KiB |
| Control connections | 4 |
| Ordinary command deadline | 5 seconds |

Control connections use their own request, reply and subscriber limits. Obtain
one with `scope.server.open_control(session: ref)`. `exchange` returns guarded
`GuardedReply` blocks with `:boundary_window` attribution. It makes no claim of
final command completion. Outside-block events arrive through `events.next` or
an explicit `subscribe`; consumer callbacks run outside the parser. Reliable
subscriptions raise on overflow. Tail subscriptions report dropped ranges.
Cancelling a dispatched, undrained exchange closes that connection.

`pause_output(pane_id:)` and `resume_output(pane_id:)` retain guarded evidence
and report possible output loss through gap events. A requested-action gap
does not prove that the action took effect. Close a connection before passing
it as `reconnect:` to `scope.server.open_control`; the replacement stays owned
by that scope and reports a new generation plus a gap with unknown loss.
Subscriptions expose their `generation`; prior subscriptions stay closed.
Reconnect and resume never replay requests or missed output.

The development bundle pins Async 2.46 and io-event 1.22. The
[compatibility workflow](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml)
exercises the selected Ruby/tmux versions on Linux and macOS and retains
per-revision results. Package builds and tests do not publish this gem.
