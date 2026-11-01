# Changelog

Notable changes to `libtmux-async`.

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: pin an exact version to avoid a break.

The gems are released together at one version, so every release has a section
here. Changes that span gems, such as documentation, CI and release tooling, are
in the [main changelog](../../CHANGELOG.md).

## 0.1.2 (unreleased)

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
