# Contributing

This repository contains the bootstrap for libtmux for Ruby. It has no library
implementation, package manifest, test suite, or release workflow yet.

Read [AGENTS.md](AGENTS.md) for change discipline and [WRITING.md](WRITING.md)
for prose and commit conventions.

## Setup

[.tool-versions](.tool-versions) pins the development interpreter. It does not
establish a supported Ruby version range.

Install the pinned tool with mise:

```console
$ mise install
```

No dependency installation or build command exists at this stage. Document
those commands here when the corresponding tooling is added.

## Checks

For bootstrap documentation and configuration changes, review the diff, check
relative links and symlink targets, and confirm that ignore rules leave source
and shared configuration visible to Git.

Check unstaged changes for whitespace errors:

```console
$ git diff --check
```

Check staged changes before committing:

```console
$ git diff --cached --check
```

As executable checks are added, keep them in the appropriate loop. Measure the
whole command, including startup and setup. Libraries should aim for the
stretch budgets.

| Loop | Budget | Stretch | Scope |
| --- | --- | --- | --- |
| Inner | Under 5 seconds | Under 2 seconds | Tests for the changed code |
| Mid | Under 30 seconds | Under 10 seconds | Unit suites, lint, generated-file checks |
| Outer | Under 5 minutes | Under 60 seconds | Type checks, builds, integration suites, full matrices |

Run the inner loop after each edit, the mid loop after each change and before
handoff, and the outer loop before a code commit or pull request.

Keep network access, installs, production builds, browsers, sleeps, and broad
corpus scans out of the inner and mid loops. Treat a timeout or wait over one
second as a structural bug: investigate the cause and use events or
subscriptions instead of sleeps. Tag slow tests with a one-line reason and
put them in the outer loop. Fix an over-budget loop before adding tests; do
not raise its budget.

Benchmarks are separate from these loops. Keep a run below ten minutes and a
full sweep below one hour; reduce the workload if needed.

## Testing tmux behavior

When implementation work begins, verify tmux behavior against a real server.
Use focused unit tests for code that does not need tmux. A bug fix should carry
a regression test shown to fail for the original defect. Avoid tests that
only repeat implementation details.

Every test or probe must own an isolated socket and temporary directory named
for this port, using a `libtmux-ruby-` prefix. Address that socket explicitly
with `-S` or `-L`, clear inherited `TMUX` and `TMUX_PANE` for child commands,
and clean up only the server and files created by that run. Never use the
default tmux server or sweep another port's temporary files.

Record the actual tmux version when behavior depends on it. A passing subset
does not establish support for an entire version range.

## Pull requests

Keep one subject per pull request and one logical change per commit. Review
the complete diff, preserve unrelated work, and stage explicit paths.

Describe the concrete problem and resulting behavior. Report the commands run,
their elapsed times, and what passed, failed, or was skipped. Include measured
evidence for performance claims and migration guidance for incompatible
behavior. Follow [WRITING.md](WRITING.md) for the commit message format.

Do not claim a package, supported platform, or public API until it exists and
has been verified. Publishing packages, releases, or tags requires a release
request; bootstrap work does not establish a release process.
