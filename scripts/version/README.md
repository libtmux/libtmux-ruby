# version

Sets the version of the four gems in one step, so they stay in lockstep.

`rake 'version:bump[VERSION]'` runs it. It updates each gem's `version.rb`, the
exact sibling dependencies in the gemspecs, the local entries in
`Gemfile.lock` and the artifact example in `.github/CONTRIBUTING.md`. It
rejects a missing or invalid version, inconsistent input files and a backward
bump, and repeating a version changes nothing. It writes no release notes,
commits, tags, pushes or uploads. The [release guide](../../docs/releasing.md)
puts it first in the release steps.

## Tests

[`tests/`](tests) bump a temporary repository and check each rejection.

```console
$ bundle exec scripts/check unit scripts/version/tests/version_test.rb
```
