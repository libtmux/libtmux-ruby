# docs

Renders the guides and the YARD API reference into a directory, then checks
every local link and fragment in the rendered pages.

It renders the Markdown documents the example manifest lists plus `AGENTS.md`
and the three guides under `.github/`, runs YARD over the gem sources, and
fails on a YARD warning, a link to a page that does not exist or a fragment
that no page defines. External URLs are not checked.

`scripts/check outer` runs it into a temporary directory:

```console
$ bundle exec ruby scripts/docs/docs
```

Keep the rendered pages in a directory that is absent or empty:

```console
$ bundle exec ruby scripts/docs/docs --output build/site
```

## Tests

[`tests/`](tests) write two small HTML pages and check that a missing
destination and a missing fragment each fail.

```console
$ bundle exec scripts/check unit scripts/docs/tests/docs_test.rb
```
