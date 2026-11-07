# Changelog

Notable changes to `libtmux-async`.

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: pin an exact version to avoid a break.

The gems are released together at one version, so every release has a section
here. Changes that span gems, such as documentation, CI and release tooling, are
in the [main changelog](../../CHANGELOG.md).

## 0.1.3 (unreleased)

- `Async::Server.open` raises `UnsupportedFeatureError` in the `admission`
  phase, as `Async::Server.start` does. In 0.1.2 it raised `ArgumentError`,
  because it ran the core factory against the facade's constructor. Open the
  core server and pass it to `LibTmux::Async.open(server:)`.
- **Behavior change:** `Async::Server.new`, `Async::ControlConnection.new` and
  `Async::ControlSubscription.new` are private. Read the facade from
  `scope.server` and open control connections with
  `scope.server.open_control(session:)`.

## 0.1.2 (2026-11-04)

No entries for `libtmux-async`.

## 0.1.1 (2026-10-31)

No entries for `libtmux-async`.

## 0.1.0 (2026-10-25)

No entries for `libtmux-async`.

## 0.1.0.alpha.3 (2026-10-24)

### libtmux-async

- `ControlSubscription#next` ends the stream with `StopIteration`. It used to
  return `nil` at the end of a stream, because `Kernel#loop` swallowed the
  exception. (#37)

## 0.1.0.alpha.2 (2026-10-18)

No entries for `libtmux-async`.

## 0.1.0.alpha.1 (2026-09-20)

### libtmux-async

- Run commands concurrently inside an application-owned Async task with
  `LibTmux::Async.open`. `Scope#map` bounds concurrency and returns results
  in input order. [Concurrent capture](../../examples/async_cancel.rb).
- Use Async control connections and event subscriptions. Scope exit retires
  owned clients and tasks while preserving the borrowed daemon.
  [Async guide](../../gems/libtmux-async/README.md).
