# Changelog

Notable changes to `libtmux-workspace`.

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: pin an exact version to avoid a break.

The gems are released together at one version, so every release has a section
here. Changes that span gems, such as documentation, CI and release tooling, are
in the [main changelog](../../CHANGELOG.md).

## 0.1.2 (unreleased)

## 0.1.1 (2026-10-31)

- **Behavior change:** `libtmux-workspace load` and `plan --live` no longer
  need `--socket`. Without it they use the same choice as `Server.new`, so a
  command that failed with status 2 for a missing socket now acts on the
  server tmux would pick. (#71)

## 0.1.0 (2026-10-25)

No entries for `libtmux-workspace`.

## 0.1.0.alpha.3 (2026-10-24)

No entries for `libtmux-workspace`.

## 0.1.0.alpha.2 (2026-10-18)

No entries for `libtmux-workspace`.

## 0.1.0.alpha.1 (2026-09-20)

### libtmux-workspace

- Load YAML or JSON with `LibTmux::Workspace.load` or `.parse`, inspect a
  creation plan, then apply it explicitly. Supports the documented subset of
  tmuxp-style configuration. [Workspace example](../../examples/workspace_apply.rb).
- Validate, plan and load from the `libtmux-workspace` CLI; optionally attach
  or switch an explicit client after creation. `--version` reports the
  installed gem version without reading a configuration or contacting tmux.
  [CLI guide](../../gems/libtmux-workspace/README.md#script-it).
- Inspect partial application through `ApplyError#result`. Optional
  compensation removes only a positively identified new session after
  checking that its windows and panes belong to the apply operation.
  [Failure results](../../gems/libtmux-workspace/README.md#recover-from-a-failed-apply).
