# Releasing

The four gems share one version. Prepare changes in a PR; publish by pushing
a matching `vVERSION` tag after the merged commit passes compatibility CI.
The examples below use the initial alpha, `0.1.0.alpha.1`.

## One-time account setup

Before the first tag, create a
[pending trusted publisher](https://rubygems.org/profile/oidc/pending_trusted_publishers)
for **each** gem: `libtmux`, `libtmux-async`, `libtmux-mcp` and
`libtmux-workspace`. Use the same values for all four:

| RubyGems field | Value |
| --- | --- |
| Repository owner | `libtmux` |
| Repository name | `libtmux-ruby` |
| Workflow filename | `release.yml` |
| Environment | `release` |
| Workflow repository fields | Leave blank |

Use the RubyGems account that should own the new gems. The first successful
upload converts each pending publisher into a publisher for that gem. For an
existing gem, configure its trusted publisher instead. See the
[RubyGems guide](https://guides.rubygems.org/trusted-publishing/).

In GitHub's repository settings, create the `release` environment. Allow
deployment from selected **tags** matching `v*`; add a required reviewer and
prevent self-review where the repository's plan supports those controls.
Protect release tags against replacement or deletion. Restrict changes to
the release workflow through normal code review. See
[GitHub environment configuration](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

No RubyGems API secret is needed. The credentials action exchanges GitHub's
OIDC identity for a short-lived upload credential. Only the publishing job
has `id-token: write`; PR validation has read-only repository access and no
publishing credentials.

## Prepare a version

From a development checkout with the bundle installed:

```console
$ mise exec -- bundle exec rake 'version:bump[0.1.0.alpha.1]'
```

The task updates each conventional `version.rb`, exact sibling dependencies,
local entries in `Gemfile.lock`, and the README artifact example. External
dependency versions stay unchanged. It rejects missing or invalid versions,
inconsistent input files and backward bumps. Repeating the same version is
safe. The unpublished `0.1.0.pre` placeholder may become `0.1.0.alpha.1`,
although RubyGems sorts that alpha below `.pre`.

For the next alpha, pass `0.1.0.alpha.2`. Review and update
[CHANGELOG.md](../CHANGELOG.md) for every release; the version task does not
write release notes, commit, tag, push or upload.

```console
$ /usr/bin/time -p mise exec -- bundle exec scripts/check outer
```

Commit the preparation changes. From that clean commit, build and exercise
the prospective release without a tag or registry access:

```console
$ /usr/bin/time -p mise exec -- bundle exec rake 'release:dry_run[v0.1.0.alpha.1]'
```

This builds all four gems into `pkg/release/`, records their source commit
and SHA-256 digests in `release.json`, checks package metadata and contents,
and runs the installed-package checks outside the checkout. It cannot upload.
The same dry run runs on pull requests. To check retained files alone:

```console
$ mise exec -- bundle exec rake 'release:verify[v0.1.0.alpha.1]'
```

An existing artifact set must match the requested version and commit. Move
an obsolete local `pkg/release/` aside before validating a different commit;
do not discard files from a partially published release.

## Publish an approved release

These commands publish after account setup, review and merge. Finalize the
changelog before tagging: remove the unreleased heading for this version and
record the release date. The GitHub prerelease uses that file as its notes.

On `master`, update to the approved commit:

```console
$ git pull --ff-only origin master
```

Require a successful master compatibility run for that exact commit:

```console
$ mise exec -- bundle exec scripts/release-ci "$(git rev-parse HEAD)"
```

Create the annotated version tag:

```console
$ git tag -a v0.1.0.alpha.1 -m 'Release 0.1.0.alpha.1'
```

Push only that tag to start publication:

```console
$ git push origin refs/tags/v0.1.0.alpha.1
```

The [Release workflow](../.github/workflows/release.yml) validates the tag,
requires successful compatibility for its exact commit, tests the entire
artifact set and retains it before requesting credentials. It uploads core,
Async, MCP and workspace in that order, then creates a GitHub prerelease with
the same files. Publishing does not change versions or create tags.
Releases run serially; an active publication is not cancelled by a newer tag.

Verify all four version pages on RubyGems and the GitHub prerelease. The
publisher compares each registry SHA-256 with `release.json` after upload;
all four must match before GitHub release creation. A consumer can then
install the explicit prerelease:

```console
$ gem install libtmux --version 0.1.0.alpha.1
```

## Recover a partial release

Open the failed Release run and download its `rubygems-release` artifact
before its 90-day retention expires. It contains the exact four gems and
manifest. Keep it until every registry upload and GitHub release succeeds.

Correct account or environment configuration, then use **Re-run failed jobs**
on the same run. A full rerun also restores that run's retained artifact set;
it does not replace it. Never move the tag or rebuild partially uploaded gems.

The publisher checks every existing registry artifact before any new upload.
It skips an existing version only when its SHA-256 matches the retained gem.
A mismatch stops the release. Network errors, registry failures and an upload
not yet visible in the registry stop the job; retry after resolving the cause.
A version is considered absent only when both the version API and the
yanked-aware downloads API return HTTP 404. Known yanked versions stop the
release. Registry preflight cannot reserve names or make four uploads atomic;
a concurrent registry change can still interrupt publication.

If retained files have expired, stop and recover the original bytes from a
maintainer's saved artifact set before proceeding. A digest mismatch needs
investigation and usually a new coordinated version; yanking does not make
the old version reusable.

The GitHub job can also resume. It verifies the retained source, remote tag
commit, prerelease status and every existing asset's SHA-256, including
`release.json`, before uploading missing files. A complete matching prerelease
needs no uploads. Conflicting, duplicate or unexpected assets stop the job;
it never replaces them. API errors stop the job; only HTTP 404 permits
creation. Rerun the GitHub job after resolving the reported cause.

An interrupted GitHub upload can leave a draft. Automatic retry refuses
existing drafts. Inspect and preserve its assets before removing that draft;
keep the tag and retained artifact set, then rerun the job.

## Authentication and attestations

Trusted publishing authenticates the upload. This workflow does not generate
or upload signed build attestations. Its SHA-256 manifest supports artifact
verification and retry; it is not a signed provenance statement. The
[credentials action](https://github.com/rubygems/configure-rubygems-credentials)
provides OIDC authentication, not attestations.
