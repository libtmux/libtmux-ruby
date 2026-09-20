# Contributing

This repository contains the unreleased libtmux gem suite. Installed-import
tests establish package boundaries and execute consumer APIs and documentation
recipes. Compatibility CI records the exact Ruby, tmux and operating-system cells.

Read [AGENTS.md](../AGENTS.md) for change discipline and [WRITING.md](WRITING.md)
for prose and commit conventions.

## Setup

[.tool-versions](../.tool-versions) pins the development interpreter. It does not
establish a supported Ruby version range.

Integration and installed-artifact tests require tmux and `/bin/zsh` 5.9.
The authored-shell tests use zsh's ZLE, `zsh/net/socket` and `zsh/system`
modules. The Linux CI job installs zsh; the macOS runner supplies it.

Install the pinned tool with mise:

```console
$ mise install
```

Keep development dependencies in the ignored local bundle directory:

```console
$ mise exec -- bundle config set --local path vendor/bundle
```

Install the development bundle outside the test loops:

```console
$ mise exec -- bundle install
```

The root Gemfile.lock records the development dependency set for all four
gems. Gem specifications declare each artifact's runtime requirements.
Declared Ruby and dependency ranges remain candidates until their matrix
cells pass; a successful bundle install establishes dependency resolution.

## Checks

Run a focused unit test through the timed inner loop:

```console
$ /usr/bin/time -p mise exec -- bundle exec ruby test/unit/process_test.rb
```

Run all unit tests and Ruby syntax checks in the mid loop:

```console
$ /usr/bin/time -p mise exec -- bundle exec ruby scripts/check mid
```

Run unit, isolated tmux integration, installed-artifact recipes and signature
consumers, rendered documentation and RBS checks in the outer loop:

```console
$ /usr/bin/time -p mise exec -- bundle exec ruby scripts/check outer
```

The same runner accepts `integration`, `packaging` and `types` separately.
It fails when a requested suite has no tests. RBS validation checks the
shipped declarations. `scripts/types --check` checks public declaration
coverage, source links and behavioral mappings.
Installed consumers check the argument and return types of exercised calls;
these checks do not establish whole-program static typing. The outer
packaging test builds artifacts, copies only their declared dependency
closure from the installed bundle, then installs the project gems into
temporary gem homes and imports them outside the checkout. It uses no
network and preserves the host gem installation.

Build distributable artifacts locally:

```console
$ mise exec -- bundle exec rake build
```

Artifacts appear in ignored `pkg/`. No publication happens during the build.
The [release guide](../docs/releasing.md) covers coordinated version bumps,
retained-artifact dry runs and first-time trusted-publisher setup.
The mid loop checks generated fields/schema/signatures, the public API
reference and the executable example manifest. The outer loop installs each
declared dependency closure, runs the copied recipes outside the checkout,
renders YARD and Markdown, and checks local links and fragments. External URL
availability is separate.
The full support matrix, benchmarks and implementation type coverage remain
separate required gates; one local outer pass does not establish them.

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
Inspect the comparison configuration without starting tmux:

```console
$ mise exec -- bundle exec ruby scripts/bench plan
```

The [benchmark guide](../docs/benchmark.md) defines equivalent workloads,
measurement limits, durable evidence and cleanup checks.

## Testing tmux behavior

Verify tmux behavior against a real server.
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
