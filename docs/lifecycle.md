# Ownership, discovery and find or create

## Own a session, window or pane

An ordinary program uses your running default tmux daemon. It creates one session, reuses it by exact name, creates and cleans up a window and pane, then adopts a window created through the borrowed API. Each example includes its imports. The repository harness supplies a private endpoint through the child environment when testing the same source.

<!-- example: lifecycle -->
```ruby
# frozen_string_literal: true

require "libtmux"
require "securerandom"

LibTmux::Server.open do |server|
  name = "ruby-lifecycle-#{SecureRandom.hex(4)}"
  server.owned_session(name: name, command: ["/bin/cat"]) do |session|
    reused = server.find_or_create_session(name: name, command: ["/bin/cat"])
    puts "session reused: #{!reused.created?}"
    window = session.find_or_create_window(name: "worker", command: ["/bin/cat"])
    window.use do |resource|
      pane = resource.find_or_create_pane(identity: "worker", direction: :horizontal, command: ["/bin/cat"])
      pane.use { puts "pane created: #{pane.created?}" }
    end
    session.new_window(name: "adopt", command: ["/bin/cat"]).adopt do |window|
      puts "adopted panes: #{window.list_panes.length}"
    end
  end
end
```
<!-- /example -->

## Find running servers

This example scans direct entries in the directory containing the selected endpoint. Omit `roots:` to scan the captured endpoint directory, the configured `TMUX_TMPDIR/tmux-UID` directory and `/tmp/tmux-UID`. Discovery returns successful endpoints, per-path diagnostics and a truncation flag. Symlinks are skipped; hard links to one socket are deduplicated. The entry limit includes roots. Probe and total time limits bound client waits. Discovery uses `-N` and cannot launch a daemon. It does not inventory arbitrary sockets elsewhere on the machine.

<!-- example: lifecycle_discovery -->
```ruby
# frozen_string_literal: true

require "libtmux"

endpoint = LibTmux::Endpoint.new
result = LibTmux::Server.discover(roots: [File.dirname(endpoint.socket_path)])
puts "servers: #{result.servers.length}"
raise "discovery was truncated" if result.truncated?
```
<!-- /example -->

## Adopt a daemon

This cleanup demonstration starts a private foreground daemon because the example destroys the entire server. `Server.start` retains its own child-process observer. `adopt` also captures a daemon generation receipt. Exiting the inner block kills the accepted daemon; the outer block retires its client and startup files.

<!-- example: lifecycle_server -->
```ruby
# frozen_string_literal: true

require "libtmux"

LibTmux::Server.start do |server|
  server.new_session(name: "ownership", command: ["/bin/cat"])
  server.adopt do |daemon|
    pane = daemon.list_panes.first
    pane.adopt { puts "server adopted: true" }
  end
end
```
<!-- /example -->

## Ownership and failure rules

`server.adopt`, `session.adopt`, `window.adopt` and `pane.adopt` return an `OwnedResource`, or run a block and clean up at block exit. `owned_session`, `owned_window` and `owned_pane` create a resource and return an owner with the same block option. `with_session` keeps its existing call shape and now uses the receipt-backed session scope. A window owner kills the window, its panes and every linked copy. A moved pane or window retains its ID and cleanup follows that ID. Plain lookup, `new_session`, `new_window`, `split`, and client `Server.open` do not adopt remote resources.

An owner retains its borrowed server binding, a hard-link route to the accepted Unix socket, PID, start time, object ID and a random 32-character generation token. The library initializes the reserved server option `@libtmux_owner_generation` only when it is absent. Empty or malformed existing values fail acquisition. Callers must not change or shadow this reserved option while owners remain open. Destructive commands check the receipt inside tmux. A replacement daemon cannot become the target of a retained route; the generation guard also rejects a simulated numeric identity collision. Keep the borrowed server client open until its owners close.

`OwnedResource#close` succeeds once and then does nothing. A failed close leaves `closed?` false and retains the exception in `cleanup_error`, so callers can retry. A block failure survives a successful cleanup as the original exception object. If both fail, `CleanupError#body_error` and `cleanup_error` retain both original exception objects; `recovery` exposes the owner for retry. Ruby `ensure` handles return, break, throw and exceptions. Ruby asynchronous exceptions are deferred during receipt handoff and cleanup. A cancellation token observed after creation triggers receipt-based rollback.

Adoption checks `cancel:` before acquisition and after accepting a complete, valid receipt. Cancellation before acquisition leaves the borrowed target intact. Cancellation after ownership acceptance destroys the adopted server, session, window or pane through that receipt and raises `Cancelled` without returning an owner or entering the block. If destruction fails, `CleanupError` retains the cancellation, cleanup failure and recovery owner for retry. Late cancellation of `server.adopt` therefore destroys the accepted daemon, just as leaving its owned block does.

Creation prints the object ID and daemon identity in the creating command. Extra data after a complete receipt triggers rollback; a later pane-identity verification failure does too. If rollback fails, `CleanupError#recovery` retains the owner. Without a complete receipt, `OutcomeUnknown` reports uncertainty and the retained endpoint is the inspection boundary. It does not guess which object to delete. Timeouts and killed runner processes can still lose a receipt; an external fixture must own whole-server teardown for those cases.

The Async facade uses its existing bound core server for ownership commands and cleanup. It defers Async task cancellation during receipt handoff and allows cleanup after body cancellation. These ownership calls use the blocking core executor; ordinary Async commands keep their scheduler transport. Async permits a second cancellation to interrupt a deferred task. Repeated forced cancellation and whole-runner crash recovery require an outer owner; they are not a promise of this block API.

## Matching and concurrency

`Server.find_or_create` returns `Acquisition[Server]`. A fresh endpoint receives a foreground daemon through atomic no-overwrite socket publication; a reused endpoint remains borrowed. Stale sockets and ordinary files are errors and stay in place. Close the returned server client after a reused acquisition. A created result has an owner; `Acquisition#use` cleans up only a created resource.

`find_or_create_session` matches one exact session name. Names containing dot, colon, backslash or control characters fail before creation because tmux rewrites those characters. Existing borrowed creation methods keep their previous input behavior. `find_or_create_window` matches a window name within one session and rejects multiple matches. It rejects backslash and control characters that tmux rewrites in window names. `find_or_create_pane` matches the literal local `@libtmux_pane_identity` option within one window and rejects duplicates. The library writes and verifies that identity for a created pane; it rolls back if that step fails.

Find-or-create calls share one bounded gate within a Ruby process, across server handles and threads. Calls for different endpoints also share that gate. A caller waiting for it uses the operation deadline. Raw tmux commands and other processes do not join this serialization. They can rename, link, move or create objects during a lookup. This API makes no cross-process atomicity claim. tmux still rejects duplicate session names, and socket publication still refuses an occupied pathname.

Session, window and pane find-or-create calls check `cancel:` before gate admission, during lookup and before returning the acquisition. A waiting call checks the token at intervals of at most 0.05 seconds while another call holds the gate, subject to thread scheduling. Cancelled reuse leaves the existing resource borrowed and intact. Cancellation after creation rolls back only the newly owned resource, including a pane whose identity was written before cancellation arrived. The same operation deadline covers the gate, lookup and creation.

## Example checks

The example manifest binds each displayed code block to its complete Ruby source. The existing Markdown/YARD renderer and installed-gem recipes check those source excerpts and execute them. The external harness passes `LIBTMUX_SOCKET_PATH`, validates output and remaining sessions, then observes its foreground daemon exit before removing its fixture. A bounded worker executor retires timed-out example processes; a crashed example worker still reaches outer fixture cleanup. Killing the harness process itself requires a separate supervisor and is not covered by that in-process ensure. Host `ENV` stays unchanged. Astro, Sphinx and Python doctest adapters remain shared project scope; this Ruby repository does not claim executed native integrations for those formats.
