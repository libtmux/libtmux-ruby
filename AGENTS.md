# Agent instructions

Follow the existing project conventions and keep changes scoped to the
requested work.

## Change discipline

- Make the smallest coherent change that solves the verified problem. Keep
  unrelated cleanup out of it.
- Reuse an existing file, helper, API, or test before adding a new one.
- Keep new APIs private until a caller outside the library needs them.
- Add a file for a distinct responsibility or independent reuse, not a
  single-use helper or a one-line re-export.
- Add tests for critical behavior. Show that a new regression test fails for
  the intended reason before relying on its passing result.
- Verify claims against the checked-out source and the commands actually run.
- Prefer `rg`, `ag`, and `fd` for discovery.

## Which policy applies

- Setup, testing, tmux isolation, and pull requests:
  [CONTRIBUTING.md](CONTRIBUTING.md).
- Documentation, user-facing text, comments, and commit messages:
  [WRITING.md](WRITING.md).

Each guide is the single home for its subject. `CLAUDE.md` is a relative
symlink to this file; keep the instructions here.
