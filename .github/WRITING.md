# Writing

This guide governs documentation, user-facing text, source comments, commit
messages, changelogs, and release notes. [CONTRIBUTING.md](CONTRIBUTING.md)
governs development workflow.

## Voice

Lead with the conclusion or observable behavior, then give the evidence or
constraints needed to understand it. Use active voice, present tense, concrete
nouns, and short sentences. Assume the reader has no conversation history.

State facts rather than praising them. Replace vague claims such as "robust"
or "optimized" with the handled failure or measured improvement. Remove filler,
promotional language, emoji, agent attribution, and tool metadata.

Use literal identifiers and consistent names: Ruby, libtmux, tmux, server,
session, window, and pane. Explain what a referenced issue or decision means;
its identifier alone is not an explanation.

## Documentation

Document what exists. Distinguish a bootstrap, an implemented capability, a
tested capability, and a published release. Do not copy compatibility promises,
installation commands, or package names from another port without evidence.

A README should explain the purpose, status, requirements, installation, and
smallest working example. Keep detailed API contracts in API documentation.
Commands must work as written; examples must use real interfaces and state
their prerequisites. A performance claim needs a measurement and a command
that reproduces it.

For public APIs, describe what callers can rely on: inputs, defaults, empty
values, ownership, mutation, ordering, blocking, concurrency, and errors where
relevant. Use the documentation syntax chosen by the repository's tooling.
Do not repeat a signature in prose or invent removal versions.

Error messages name the failed operation, the concrete cause, and a useful
next action when one exists. Help text states option semantics and defaults.

## Source comments

Keep comments that preserve a non-obvious invariant, protocol constraint,
platform quirk, upstream workaround, or ordering requirement. Prefer one or
two lines. A comment must save rediscovery work, state its fact directly, and
remain true without hand-syncing values owned by the code.

Delete narration of the next lines, duplicated defaults or counts, speculative
future work, and history already recorded by Git. Put rejected alternatives
and the reasoning behind a change in the commit message. Preserve directives
and markers used by tools.

Public documentation and examples may explain minimal usage and contracts;
they still need to be concise and accurate.

## Markdown and examples

Use plain CommonMark with descriptive headings and links. Put a blank line
before lists and after headings. Wrap repository prose at 80 columns where
practical; do not break URLs, identifiers, or tables to meet the width. Do not
hard-wrap issue or pull request bodies.

Avoid personal information, machine-specific paths, brittle line references,
bare commit hashes, and counts that duplicate source state.

### Code blocks

Code blocks are paste-and-run units:

- Put one command in each block. An explicit `&&`, `;`, or `\` continuation
  counts as one command.
- Put explanations in prose above the block, not comments inside it.
- Mark shell commands as `console` and prefix them with `$ `.
- Split long commands with `\`, one flag or flag-value pair per continuation
  line, with positional arguments last.
- Use the actual language tag for source examples. Keep executed examples
  valid for their runner.

Show recent commits as a graph:

```console
$ git log \
    --max-count=10 \
    --graph \
    --oneline
```

## Examples

<!-- shared:examples -->

An example is code written for a reader: a program under `examples/`, code in
a doc comment or docstring, and every fenced block in a README or docs page.
Shell blocks also follow [Code blocks](#code-blocks).

The text between the shared markers is the same in every libtmux port.
Change it in all of them together.

### Width

- **Examples stay within 80 columns.** They render in fixed-width boxes that
  scroll sideways, and 80 columns fits a libtmux.org code block in a
  laptop-width window. Comments inside examples wrap at 80 too.
- **The width check enforces it.** It reads the tracked files that
  `.github/example-width.toml` names and fails on a wider line. It measures
  the whole source line, so code in a doc comment counts its indent and
  comment marker. It skips output (a fence tagged `text`, and what a
  `console` block prints), hidden setup lines, and a line that is only a URL;
  an untagged fence counts as code.
- **A line that must stay wider is listed there with its reason.** An entry
  that no longer matches a line fails the check, so no stale entry stays.
- **The formatter's width is the hard limit for all other source.** Example
  directories set their formatter to 80 where the formatter takes a width.

### Reaching 80

- **Change the code, not the line breaks.** A formatter rejoins any line that
  fits its width. Name a sub-expression, use a short example name, hide setup
  the reader does not need, or print less.
- **Break at the outermost level when a break is still needed:** after an
  opening parenthesis with one argument per line, one call per line in a
  chain, one field per line in a literal.
- **Put a comment on its own line above the code it explains.** Never trail
  one after code in an example, unless the repository's example runner reads
  it there, as with an assertion marker.
- **Break a long string at a word boundary,** never inside a tmux format
  (`#{...}`) or an escape sequence; the joined text stays the same.
- **Continue a long command in a `console` block the way its shell does:**
  `\` after a `$ ` prompt, a backtick after `PS> `, one flag per continuation
  line.

### What never breaks

- **Output a test compares.** Wrapping it changes what the test expects.
- **A block copied from a source file.** Fix the width in the source and run
  the sync command; never edit the copy.
- **Marker lines and URLs,** which tools and readers take whole.

<!-- /shared:examples -->

### In this repository

- **Hard limit:** syntax_tree, run by `scripts/format`; `EXAMPLE_WIDTH` sets
  80 for `examples/`, and the version is pinned in `Gemfile.lock`. Check
  formatting with `bundle exec scripts/format --check`. The width check is
  `python3 scripts/check_example_width.py`; CI adds `--self-test`.
- **Not formatted:** Markdown fences and comments under `examples/`; the
  width check holds them to 80.
- **Runs, compiles, exempt:** a fenced block under `<!-- example: ID -->` is
  an excerpt of a `# docs:begin NAME` region in a program registered in
  `examples/manifest.json`, and the tests run that program. An unregistered
  `ruby`, `yaml`, or `json` fence fails the check; `console` and `text`
  fences need no registration. There is no compile-only marker.
- **Compared output and copied blocks:** output a test compares keeps its
  exact text, and an excerpt is never edited by hand. Edit the program, then
  run `bundle exec scripts/format`, which runs `scripts/examples --write` and
  `scripts/types --write` to re-sync every copy.

Bad, over 80:

```ruby
script =
  'printf "%s:%s" "$EXAMPLE_CONTEXT" "$TMUX_PANE"; printf "\\000\\377" >&2; exit 9'
```

Good, one command per array element, joined back into the same string:

```ruby
script = [
  'printf "%s:%s" "$EXAMPLE_CONTEXT" "$TMUX_PANE"',
  'printf "\\000\\377" >&2',
  "exit 9"
].join("; ")
```

## Commit messages

Use the sibling ports' scoped format:

```text
Scope(type[detail]): Concise description

why: Explain the reason or effect.

what:
- State the concrete change
```

Use an imperative subject of at most 50 characters and body lines of at most
72 characters. Keep each commit focused on one topic. Separate `why:` and
`what:` with a blank line; a self-explanatory single-file change may omit the
body. Preserve URLs and identifiers when wrapping.

Common types are `feat`, `fix`, `refactor`, `docs`, `chore`, `test`, and `style`.
Agent guidance may use `ai(rules[AGENTS])`. A change confined to a configuration
file may use `filename: Description`. Include the reason and concrete changes
when a commit spans multiple files or needs context.

Do not use vague subjects, emoji, attribution trailers, or pull request
numbers in ordinary commits. Keep intermediate attempts and rejected
approaches in commit history when they explain a decision, not in product
documentation.

## Pull requests, changelogs, and releases

Describe the final change for someone who has not read the conversation. Lead
with the problem and resulting behavior, then give relevant validation and
limits. Name the checks that ran and distinguish passing, failing, skipped,
and unverified work.

When a changelog exists, record caller-visible changes under its unreleased
section. State changed defaults and incompatibilities with migration guidance.
Do not invent versions or release dates. Mention old behavior only when users
of a published release experienced it.

Release notes explain why an upgrader should care and what action is needed.
Link the detailed changelog instead of repeating it. Internal refactors and
branch history belong in commits unless they affect users.
