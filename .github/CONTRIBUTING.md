# Contributing

This repository contains the libtmux gem suite. Installed-import
tests establish package boundaries and execute consumer APIs and documentation
recipes. Compatibility CI records the exact Ruby and tmux cells on Linux.
macOS is supported on a best-effort basis, and CI coverage for it is highly
limited: no job runs there, so a macOS-only regression is not caught before
merge.

Read [AGENTS.md](../AGENTS.md) for change discipline and [WRITING.md](WRITING.md)
for prose and commit conventions.

## Setup

[.tool-versions](../.tool-versions) pins the development interpreter. It does not
establish a supported Ruby version range.

Integration and installed-artifact tests require tmux 3.3a or newer and
`/bin/zsh` 5.9. The version check tests also exercise tmux 3.2a and unpatched
3.3 daemons when `LIBTMUX_TEST_TMUX` names one and
`LIBTMUX_VERSION_CHECK_CLIENT_TMUX` names a supported client.
`test/old_daemon/pre_3_2_refusal_test.rb` does the same for tmux 3.0a and 3.1c,
which tmux 3.2 clients cannot start; it also needs
`LIBTMUX_VERSION_CHECK_EXPECT` set to the release under test. CI sets that
variable to `refused` or `supported` for the other version check tests, and
they fail in CI when it is missing.
The authored-shell tests use zsh's ZLE, `zsh/net/socket` and `zsh/system`
modules. The Linux CI job installs zsh.

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
$ /usr/bin/time -p mise exec -- bundle exec scripts/check mid
```

Run unit, isolated tmux integration, installed-artifact recipes and signature
consumers, rendered documentation and RBS checks in the outer loop:

```console
$ /usr/bin/time -p mise exec -- bundle exec scripts/check outer
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

README commands are tested too. The unit suite lints the READMEs in
`test/unit/readme_blocks_test.rb`: one command per console block, `gem install`
names, flags against each executable's `--help`, linked MCP tool names, gem
headings, reference-link labels and in-page anchors. The integration suite in
`test/integration/readme_commands_test.rb` runs every `tmux`,
`libtmux-workspace` and `libtmux-mcp` command and client configuration a README
prints, in a private directory, and compares printed output. A README command
without a verifier fails; add one there.

Ruby, YAML and JSON blocks in a README are excerpts of programs under
`examples/`, registered in `examples/manifest.json` and kept current by
`scripts/examples`. An API example lists the symbols it shows and the output it
prints, and the packaging test runs it from the installed gems and compares
that output.

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
$ mise exec -- bundle exec scripts/bench plan
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

A suite that starts from a tmux pane would otherwise send any command that
names no socket to that pane's server, because tmux follows `TMUX` ahead of
`TMUX_TMPDIR`. [test/support/sandbox.rb](../test/support/sandbox.rb) prevents
that. It removes `TMUX`, `TMUX_PANE` and every `LIBTMUX_SOCKET*` variable, makes
an `lt-rb-` directory under `TMPDIR` the process's `TMUX_TMPDIR`, and exits with
status 2 when either did not hold. `scripts/check`, `scripts/matrix`,
`scripts/bench`, `test/test_helper.rb` and the tmux fixture load it, and a
child process joins the sandbox its parent entered. `scripts/matrix` gives each
cell a sandbox of its own and checks it when the cell ends, with the cell's
tmux. A test file that starts tmux and loads none of those must require
`test/support/sandbox.rb` first.

At the end of the run, a socket anywhere in the sandbox fails the run, even
when every test passed. Every test puts its server on a socket in a directory
of its own, so a socket in the sandbox, whether tmux chose it for a command
that named none or a test named it with `-S`, is a server nothing stopped.
The sandbox stops each one with `tmux -S <socket> kill-server`, then connects
to confirm nothing answers. If one still answers, it keeps the directory and
names the sockets and the directory in the failure. Messages carry names,
never the values of environment variables.

`TMPDIR` must stay short enough for a socket path. The sandbox falls back to
`/tmp` and refuses to run when neither fits. The README runner keeps its own
`lt-rb-readme-` directory under `/tmp`. It starts servers on purpose, so it
fails a test only when one still answers after kill-server, and then keeps
the directory.

`test/unit/sandbox_test.rb` shows the sandbox with a recording `tmux` that
receives decoy selectors with the sandbox absent and none with it loaded.
`test/integration/sandbox_test.rb` is the canary: it requires the sandbox to
hold, then shows that a client naming no socket looks only in the sandbox and
that `Endpoint` resolves the default to the same path. Two controls run the
same client with another `TMUX_TMPDIR` and with an inherited `TMUX`, and
require the canary's own test to reject both.

Record the actual tmux version when behavior depends on it. A passing subset
does not establish support for an entire version range.

A command run by hand from a checkout, such as `libtmux-workspace load` or
`libtmux-mcp` with no `--socket`, picks the socket tmux would pick, so inside a
tmux pane it drives the server you work in. Keep a socket of your own in an
uncommitted `.env`, which `.gitignore` already excludes, and load it before
running one:

```console
$ echo 'LIBTMUX_SOCKET=libtmux-ruby-dev' > .env
```

```console
$ set -a && . ./.env && set +a
```

## Running CI against any tmux

The [compatibility workflow](workflows/compatibility.yml) plans its jobs with
[scripts/ci-plan](../scripts/ci-plan) from
[scripts/ci-matrix.json](../scripts/ci-matrix.json), which lists the Rubies, the
supported tmux releases oldest first, the refused releases and the development
build. A push and a pull request run the oldest and newest supported release
only (3.3a and 3.8) on every Ruby. The full scope adds every other supported
release, the refusal jobs and the development build. The
[Release workflow](workflows/release.yml) runs the full scope on the tag before
it publishes anything. The `All required cells` job is the one check to
require: it passes when every planned job succeeded and every other job was
skipped.

Run the workflow on any branch, against any tmux version, tag, branch or full
commit of github.com/tmux/tmux. Put the comma-separated list in `tmux-ref`,
with `scope=custom`:

```console
$ gh workflow run compatibility.yml \
    --ref my-branch \
    -f scope=custom \
    -f tmux-ref=3.6,master
```

A supported release runs as a matrix cell, on every Ruby unless `ruby` names
some. A refused release runs its refusal job. Any other ref, and the
development build, is built from source by `scripts/build-tmux` at the commit
it names and runs the outer suite on the newest Ruby, or on the Rubies that
`ruby` names. The `os` input picks the Ubuntu image.

The `tmate` input opens a [tmate](https://github.com/mxschmitt/action-tmate)
session on exactly one job, before the tests or after a failure. The session
admits only the GitHub account that dispatched the run and ends after 30
minutes. The plan refuses it when the run has more than one job:

```console
$ gh workflow run compatibility.yml \
    --ref my-branch \
    -f scope=custom \
    -f tmux-ref=master \
    -f ruby=4.0.7 \
    -f tmate=on-failure
```

Run every job a release runs, without tagging:

```console
$ gh workflow run compatibility.yml \
    --ref my-branch \
    -f scope=full
```

Dispatched runs do not cancel one another or the push run of the same commit.

## Documentation publisher updates

[`renovate.json`](../renovate.json) groups the docs checkout and reusable
publisher in one update. Enable Renovate for this repository to open those
pull requests. Both references remain full commit hashes; their `# main`
comments tell Renovate which branch to check for updates.

Review the selected `libtmux/docs` revision before authorizing it in the
publisher's IAM trust policy. Automatic merging is disabled. The ordinary
workflow tests reject different build and publisher pins, and the docs
workflow validates the generated artifact before publication. A new pin
cannot publish until its exact workflow revision is approved in IAM.

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
