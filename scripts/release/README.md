# release

Builds, verifies and publishes the four gems, creates the GitHub release, and
checks that CI passed on the release commit first. The retained artifact bytes
are the unit of publication and of retries.

The [`release:*` Rake tasks](../../Rakefile) and the
[Release workflow](../../.github/workflows/release.yml) call these files, and
the [release guide](../../docs/releasing.md) walks a maintainer through them.

| File | What it does |
| --- | --- |
| [`release.rb`](release.rb) | `GemRelease` builds the gems into `pkg/release`, records their commit and SHA-256 digests in `release.json`, verifies that set, and pushes each gem the registry lacks. It refuses to replace a published version whose digest differs. |
| [`release_github.rb`](release_github.rb) | `GitHubRelease` creates the GitHub release from the retained artifacts, or uploads the assets an existing release lacks. |
| [`release-ci`](release-ci) | `check COMMIT` requires a successful `master` compatibility run for the commit. `restore DIRECTORY` downloads the artifact set an earlier attempt of the same run retained, and refuses a retry that finds it missing after publication started. |

Require a green compatibility run for the commit about to be tagged:

```console
$ bundle exec scripts/release/release-ci check "$(git rev-parse HEAD)"
```

## Tests

[`tests/`](tests) run `GemRelease`, `GitHubRelease` and `ReleaseCI` against
injected stand-ins for the registry, `gh` and the GitHub API. Stand-in `gh`
programs show that a call is killed at its deadline and that a body that is not
JSON becomes a release error. No test reaches the network.

```console
$ bundle exec scripts/check unit scripts/release/tests/*_test.rb
```
