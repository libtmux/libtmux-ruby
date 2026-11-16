# examples

Checks that every program under `examples/` is listed in
[`examples/manifest.json`](../../examples/manifest.json), and that each
README and guide excerpt matches the program region it shows.

An excerpt is a code block between `<!-- example: id -->` markers. The manifest
names the program and region it comes from, and an API example also lists the
symbols it shows, the output it prints and the tmux capabilities it needs. The
check rejects an unlisted program, an unknown gem, duplicate ids or API targets,
a block that differs from its region, and an API example that omits a capability
its documented symbols require.

`scripts/check` runs it in the mid and outer loops, and
[`scripts/docs/docs`](../docs/docs) and
[`scripts/export-docs/export-docs`](../export-docs/export-docs) load it.

Check the manifest and every excerpt:

```console
$ bundle exec ruby scripts/examples/examples --check
```

Rewrite the excerpts from their programs:

```console
$ bundle exec ruby scripts/examples/examples --write
```

## Tests

[`tests/`](tests) build small manifests in temporary directories and break one
rule at a time, then check the committed manifest.

```console
$ bundle exec scripts/check unit scripts/examples/tests/example_manifest_test.rb
```
