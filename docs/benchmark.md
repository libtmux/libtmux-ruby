# Benchmarks

`scripts/bench` compares the current Ruby transports against an owned tmux
server. It checks equal acquisition bytes, ordered query results, physical
entities and window-link multiplicity before collecting warm samples. A run
that fails correctness or cleanup is failed evidence, regardless of its
timings.

This is a development harness requiring the repository's installed bundle.
It does not install dependencies, run during test gates, or import test
fixtures. It uses the core catalog and decoder privately to hold acquisition
and graph construction constant across transports.

## Run a comparison

Inspect the configuration without starting tmux:

```console
$ mise exec -- bundle exec ruby scripts/bench plan
```

Run the default comparison into a new, durable directory:

```console
$ mise exec -- bundle exec ruby scripts/bench run \
    --output build/benchmarks/comparison-01
```

Defaults are six samples per phase, 1/8/32 physical panes, two session links
to one physical window, four concurrent callers, and at least 8 KiB of
deterministic output per pane. Each writer runs Ruby directly with inherited
Ruby options and RubyGems disabled, waits for an explicit input message, and
emits known bytes. Pane setup, writer readiness, untimed correctness checks
and teardown are outside warm phase timings.

A smaller correctness smoke is inconclusive for performance:

```console
$ mise exec -- bundle exec ruby scripts/bench run \
    --panes 1 \
    --samples 2 \
    --payload-bytes 1024 \
    --output build/benchmarks/smoke-01
```

Use `--tmux` or `LIBTMUX_TEST_TMUX` to select an exact executable. The run
records its version and file digest. The harness addresses only its private
socket; production client spawning clears inherited `TMUX` and `TMUX_PANE`.
It never starts or kills the default server.

The output directory must be new. Every run takes the same nonblocking
measurement lock regardless of its output directory or selected binary.
Run no other tests, builds or benchmarks concurrently. The lock only excludes
other instances of this harness; it cannot establish host idleness.

One run has a nine-minute monotonic work budget, leaving room for cleanup
under the ten-minute limit. Every request and event wait is bounded to
0.5 seconds. A sweep must remain below one hour. Reduce its topology or
sample count when necessary; do not extend failed request deadlines.

## Equivalent lanes

Each lane acquires the same three framed catalog responses and one complete
history capture per physical pane. It then builds the same snapshot and
evaluates the same local criteria, including both window links. Metadata
decoding, graph validation and local query timing are separate phases.

| Lane | Actual work | Result and attribution |
| --- | --- | --- |
| `process_serial` | One subprocess per command, serially | Individual stdout, stderr and client status |
| `async_bounded` | Ordered map with four subprocess workers | Individual results; output order follows input order |
| `control_serial` | One request at a time over a persistent raw control connection | Guarded blocks with boundary-window attribution |
| `control_pipelined` | Four caller threads sharing one control connection | Complete request wires can be written before earlier replies; replies retain admission order |
| `group` | One explicit process command group | Merged bytes and final client status; individual member outcomes remain unknown |

The group lane splits its merged output only at byte lengths established by
the untimed isolated reference workload. This is a benchmark comparison
technique, not a general per-command result parser. Unexpected bytes fail
the run. Control reply checks require exactly one block for these isolated
built-in commands, without claiming that arbitrary hooks or aliases can be
attributed to a caller.

Before measurement, the harness blocks a first request on `wait-for`, forces
seven-byte writes, and witnesses the second complete request on the client
pipe before the first reply can finish. It then releases the wait and checks
both replies. The write instrumentation is removed before warm samples.
This distinguishes a wire pipeline from callers waiting behind a serialized
exchange. It does not make tmux execute waiting command queues concurrently.

A successful run reports `PASS_WITH_OPEN_GATES`: a small transport comparison
does not establish a pressure ceiling, complete process-tree resource use or the
platform/version matrix.

One persistent control client remains attached during every warm lane. This
keeps attachment-dependent catalog fields equal and makes its background
cost shared by the lanes. It also means these numbers do not describe a
process-only application with no control reader. Lane order rotates by
sample. The harness performs no automatic replay.

Cold samples create a fresh bound facade or a fresh control connection,
obtain the first reply, and retire it. Control setup includes an explicit
session-reference lookup. These samples include retirement and exclude Ruby
interpreter, Bundler and library loading. They are reported separately from
warm commands; they are not an installed CLI startup benchmark.

The mutation phase runs the same explicit layout change and pane option
writes through each lane. Untimed checks validate option values, physical
entities, links and the resulting equal-height layout. The starting tiled
layout and unset options are restored before each sample. Independent pane
writes may execute in different orders in concurrent lanes; the checked
final state is the same.

## Streaming and failure diagnostics

Streaming is a separate output product. The writer emits known raw PTY bytes
for each input sequence; a bounded subscription must reproduce every byte
in order for each pane. No screen-polling throughput ratio is calculated.
The stream record includes byte counts, event counts, a digest and the
observed first-event time. First-event timing includes input dispatch.

Each topology also checks:

- A failed group member at the first, middle and last positions. Earlier
  writes persist; later members do not run. The final client status does not
  become a fabricated status for each member.
- Cancellation after a process, Async task or control request has entered a
  server-side `wait-for`. A readiness event proves dispatch before
  cancellation; the owned client must be reaped. Already queued remote
  effects are not rolled back.
- Control cancellation before admission and rejection beyond a configured
  request capacity. These report `not_sent`; dispatched cancellation closes
  the connection and reports `possibly_sent` without replay.
- A deliberately unread reliable subscription and a bounded tail
  subscription. Reliable overflow and the tail's explicit gap must appear
  while another control command still completes.
- Writer exit status, no attached clients, reaped tracked child processes,
  reaped owned daemon and removal of the owned temporary directory.

Failure diagnostics are correctness cases, not equivalent performance
lanes. They do not establish a general capacity ceiling, every combination
of cancellation and contention, or lossless screen capture.

## Evidence and measurement limits

The evidence directory contains:

| File | Contents |
| --- | --- |
| `run.json` | Configuration, Ruby/gem/tmux versions, initial source and executable digests, limits and metric definitions |
| `samples.jsonl` | Every phase's raw counters and timings, lane, round, topology, byte/result counts and output digest |
| `diagnostics.jsonl` | Topology, partial effects, cancellation, overflow, cleanup, final source fingerprint and failures |
| `summary.json` | Overall status, whole-run elapsed time, raw-sample counts, median/min/max and open gates |

Wall and first-result times use a monotonic clock. Phase wall timing excludes
the metric reads; CPU, allocation and GC deltas include probe overhead and
background activity in the Ruby process. The recorded whole-run clock starts
after interpreter and dependency loading. Use an external monotonic command
timer when reporting total startup, setup, workload and teardown time.

The core and Async library trees and harness must have identical fingerprints
at the start and end of a successful run. Edits to unrelated MCP or workspace
sources do not invalidate this transport comparison. Loaded dependency
versions are recorded separately.

CPU counters cover the Ruby process and its reaped direct children. On Linux,
the owned daemon's CPU ticks are also recorded with their tick frequency.
Persistent clients and pane writers are not included in the direct-child CPU
counter while alive. The harness does not claim complete process-tree CPU.

Linux `/proc` supplies endpoint RSS and high-water RSS for Ruby and the owned
tmux daemon. Before each phase the harness writes `5` to each owned process's
`clear_refs` file to reset its high-water mark. The result is a kernel-reported
phase high-water mark including metric-read overhead, subject to the kernel's
RSS accounting accuracy. Reset failures have an explicit `unavailable` status;
without a successful reset, the reported high-water mark is process lifetime.
These counters do not aggregate pane programs or clients. See the
[Linux proc documentation](https://docs.kernel.org/filesystems/proc.html).
Unsupported platform observations are `null`. GC counts, allocated objects
and heap slots are Ruby observations, not tmux allocations.

Benchmark-only observers record logical queue peaks at protected state
transitions. Control and subscription observations run under their existing
mutexes; Async observations run on the scope's owning scheduler. They count
admitted requests, waiting work, running clients, queued input and retained
reply/event bytes. Completed control requests remain counted until the
caller retires its request pipes. Async retained output includes results
waiting in the ordered map. These are the library's logical byte counters;
they do not include parser scratch space, object headers or allocator slack.
Each record identifies its observed object and reports probe count and time.
Transition observer work stays included in each phase, without subtracting
an estimated cost. Meter reset and the final snapshot run outside phase wall
timing. The final snapshot cuts off probe accounting immediately before its
own mutex-exit observation.

Each acquisition also reports command-client launches, distinct observed
PIDs, exact wrapper concurrency and admitted argument bytes. The control
connection admits at most 32 requests and 1 MiB of wire input, with a 1 MiB
reply limit per request; the benchmark submits at most four concurrent
exchanges. The Async scope is bounded to four running processes, 32 admitted
requests, 4 MiB queued input and 8 MiB retained output. End-of-phase queue
observations must return to zero; caller-held results are outside those queue
counters.

Six samples support descriptive medians and the raw measurements only.
Two-sample smoke output is labeled inconclusive. This harness reports no
tail percentiles, speedup rankings or capacity thresholds. A pressure study,
complete process-tree resource accounting and the platform/version sweep
remain distinct work; do not infer them from a green small comparison.
