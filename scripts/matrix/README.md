# matrix

Runs the outer test suite in one cell of the compatibility matrix, and merges
the cell reports into one that rejects any missing, failed, skipped or stale
cell.

A cell is an operating system, a Ruby and a tmux release from
[`scripts/ci-plan/ci-matrix.json`](../ci-plan/ci-matrix.json). Each cell runs
in a sandbox of its own, and the report records the exact interpreter and tmux
binary it used.

## Who runs it

The `cell` job in
[`compatibility.yml`](../../.github/workflows/compatibility.yml) runs one cell.
The `report` job then merges every cell's report with `--require-all`.

Print every required cell without running anything:

```console
$ ruby scripts/matrix/matrix --plan
```

`--cell OS/RUBY/TMUX` runs one cell, and `--ruby VERSION=PATH` and
`--tmux VERSION=PATH` name the interpreter and tmux binary it uses. The binary
must report exactly the cell's release.

## Tests

[`tests/`](tests) covers the plan, the merge and the rules that reject a cell
without evidence.

```console
$ bundle exec scripts/check unit scripts/matrix/tests/matrix_test.rb
```
