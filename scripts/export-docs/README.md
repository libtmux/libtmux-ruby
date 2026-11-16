# export-docs

Writes the documentation export that the libtmux.org site builds the Ruby pages
from: the public API of the four gems, the guides, and the example programs with
their output and the tmux release each needs.

The `docs` workflow runs it on the selected source, and the site build reads
the result. The export covers every public method, so it fails when a public method has no
signature, source link or entry in `docs/reference/contracts.json`, when an API
example names a symbol that is not public or belongs to another gem, or when the
payload holds a machine path.
[`scripts/types`](../types) builds the API inventory it exports and
[`scripts/examples/examples`](../examples/examples) checks the examples.

Build the export without writing it:

```console
$ bundle exec ruby scripts/export-docs/export-docs --check
```

Write it to `docs/_build`, or to another directory with `--output`:

```console
$ bundle exec ruby scripts/export-docs/export-docs
```

`--source DIRECTORY` exports another checkout, which the workflow uses to
export a release branch with the current exporter.

## Tests

[`tests/packaging/`](tests/packaging) exports the checkout and checks the
inventory, the package links, the example files and determinism. It builds the
YARD registry, so `scripts/check` runs it in the packaging suite.

```console
$ bundle exec ruby -Itest scripts/export-docs/tests/packaging/docs_export_test.rb
```
