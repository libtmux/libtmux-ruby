# Writing

Repository-specific rules for documentation, YARD and source comments,
changelogs, release notes, and commits in `libtmux-ruby`. Organization-wide
voice, CommonMark wrapping, and commit conventions live in
[libtmux/.github `WRITING.md`](https://github.com/libtmux/.github/blob/main/WRITING.md);
development workflow and gates live in [CONTRIBUTING.md](CONTRIBUTING.md).

## Terminology and API documentation

Use literal identifiers and consistent domain nouns: Ruby, `libtmux`, tmux
(lowercase everywhere; rewrite a sentence rather than capitalizing it), server,
session, window, and pane.

Document what exists in this port. Distinguish a bootstrap, an implemented
capability, a tested capability, and a published release; do not copy
compatibility promises, installation commands, or gem names from another port
without evidence. A performance claim requires a measurement and a command that
reproduces it.

Public API documentation uses YARD Markdown paired with RBS declarations in
`gems/*/sig`. `scripts/docs/docs` renders YARD with `--markup markdown
--markup-provider yard` and treats any `[warn]` or `[error]` as a failure;
`scripts/types --check` audits RBS coverage, source links, and behavioral
mappings.

Describe what callers rely on beyond the RBS signature: inputs, defaults, empty
values, ownership, mutation, ordering, blocking, concurrency, and raised errors.
Do not repeat a signature in prose or invent removal versions. Error messages
name the failed operation, the concrete cause, and a useful next action when one
exists; CLI `--help` states option semantics and defaults.

## README shape

Both the root `README.md` and each gem's `README.md` are built to be scanned:

- Open with the logo block, a centered `#` title, a short pitch linking core
  APIs, and four badges in fixed order (CI, RubyGems version, `libtmux.org`, MIT
  license), followed by `gem install` and the Ruby and tmux 3.3a runtime floors
  ahead of `## Quick start`. Link only pages that return HTTP 200.
- Make each `##` heading a task in the reader's words, and each `###` heading a
  linked API name, a colon, and its job in plain words, such as
  ``### [`Server#snapshot`][server-snapshot]: one read, many queries``, linking
  its page on `libtmux.org`.
- Under each `###` heading, give a line or two linking sibling APIs, a
  self-contained example starting with its `require` calls, what it prints, at
  most one short note, and a `More:` link to the guide.
- Keep paragraphs to three lines or fewer. Omit feature inventories, patch
  versions, CI matrices, host details, and check boilerplate.
- Link every API, MCP tool, and command named in prose via reference-style links
  at the foot of the file; keep links out of code fences.
- Start a private tmux server in each example with `Server.start` rather than
  shell `tmux` setup or cleanup. Every `ruby`, `yaml`, and `json` block in a
  checked document comes from `examples/` via `<!-- example: id -->` markers
  registered in `examples/manifest.json` (`scripts/examples/examples --check`).
- Show `Server#snapshot`, `Server#explain_panes`, `Server#run_group`, and
  `Server#open_control`, each under its own heading with a tested example.
- Keep the `Gem | Require | Use it for` table in `## Packages`, then give each
  gem a `###` heading linking its GitHub directory, one summary line, and links
  to its API reference, guides, and RubyGems.
- Close with short bold-lead bullets under `## What it leaves out` and
  `## Support and status`, followed by a compact documentation and policy link
  row and the [libtmux.org](https://libtmux.org/) family line.

## Source comments and code blocks

Keep source comments only for non-obvious invariants, protocol constraints,
platform quirks, upstream workarounds, or ordering requirements, in one or two
lines. Omit narration of surrounding code, duplicated counts or defaults, and
history recorded by Git. Preserve tool directives and markers such as
`# frozen_string_literal: true` and `# docs:begin` / `# docs:end`.

Code blocks are paste-and-run units enforced by
`test/unit/readme_blocks_test.rb` and
`test/integration/readme_commands_test.rb`:

- Put one command per `console` block, prefixed with `$ `, and put explanations
  in prose above the fence rather than comments inside it.
- Split long commands with `\`, one flag or flag-value pair per continuation
  line, with positional arguments last.
- Tag source fences with their language and wrap displayed code lines within 80
  columns.

## Commits, changelogs, and releases

Follow the scoped commit and pull request rules in
[libtmux/.github `WRITING.md`](https://github.com/libtmux/.github/blob/main/WRITING.md#commits-and-pull-requests)
(`Scope(type[detail]): Concise description`, imperative subject <= 50
characters, `why:` and `what:` body lines <= 72 characters, no emoji,
attribution trailers, or pull request numbers in ordinary commits). Agent
guidance may use `ai(rules[AGENTS])`, and a single configuration file change may
use `filename: Description`.

Each published gem keeps its own changelog (`gems/libtmux/CHANGELOG.md` and
likewise for `libtmux-async`, `libtmux-mcp`, and `libtmux-workspace`) for
changes to that gem. Root `CHANGELOG.md` holds cross-gem, documentation, CI, and
release-tooling changes plus whole-release notes. Every entry lives in exactly
one file under its unreleased heading, using relative `../../` repository links
inside gem changelogs. All four gems share one `0.1.N` version; when a release
has no entries for a gem, write ``No entries for `libtmux-mcp`.`` under its
heading (`test/unit/changelog_test.rb`).
