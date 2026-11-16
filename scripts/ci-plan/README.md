# ci-plan

Plans the jobs of the `compatibility` workflow from
[`ci-matrix.json`](ci-matrix.json) and checks that every planned job passed.

`ci-matrix.json` is the one list of Rubies, supported tmux releases, refused
releases and the development build. Adding a release there is the whole change
to CI. [`ci_manifest.rb`](ci_manifest.rb) loads and validates it, and
[`scripts/matrix/matrix`](../matrix/matrix) reads it too.

## Plan

The `plan` job in
[`compatibility.yml`](../../.github/workflows/compatibility.yml) runs `plan`
first, and each later job takes its matrix from the output. A push and a pull
request plan the oldest and newest supported release on every Ruby. A release
and a dispatch with `scope=full` plan the whole table, the refusal jobs and the
development build. A dispatch with `scope=custom` plans the refs in `tmux-ref`.

Print the plan for a pull request without a runner:

```console
$ ruby scripts/ci-plan/ci-plan plan --event pull_request
```

## Verify

The `report` job runs `verify` last. It reads the `needs` result from the
`NEEDS` environment variable and fails when a job the plan scheduled did not
succeed or a job it left out did not skip.

## Built version

A leg that expects a tmux version pattern, such as `^next-` for the development
build, runs `built` after the build. It fails when the version the build
reports does not match, so a ref that resolved to another release stops the leg
before the tests.

```console
$ ruby scripts/ci-plan/ci-plan built --version next-3.8 --expect '^next-'
```

## Tests

[`tests/`](tests) holds the planner, the manifest rules and the check that the
contributor guide states the manifest's tmux range, Rubies and edges.

```console
$ bundle exec scripts/check unit scripts/ci-plan/tests/*_test.rb
```
