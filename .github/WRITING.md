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

A README is built to be scanned:

- It opens with the logo header, one line, and a quick start with the shortest
  working program.
- Task sections follow in the reader's words, ordered from first use to deeper
  use.
- A `###` heading names a linked API and its job, such as
  ``### [`Server#snapshot`][server-snapshot]: one read, many queries``.
- Under it go a sentence that names the call and its siblings, a short example
  from a tested program, where it runs and what it prints, and at most one
  short note.
- Paragraphs stay near four lines. Contract detail moves to `docs/` and is
  linked.
- Every API, tool and command the prose names is linked. Reference-style links
  sit at the foot of the file, and no link appears inside a code fence.
- Package tables and lists stay when a README is restructured.
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

Each gem keeps its own changelog, `gems/libtmux/CHANGELOG.md` for `libtmux` and
likewise for `libtmux-async`, `libtmux-mcp` and `libtmux-workspace`, and an
entry goes in the file of the gem it changes. The root `CHANGELOG.md` holds what
belongs to no single gem: a change that spans gems, documentation, CI, release
tooling and the notes that cover a whole release. An entry lives in exactly one
file. The gems share one version, so every release has a section in each file,
and a release with nothing for a gem says ``No entries for `libtmux-mcp`.``
under its heading. A link into the repository is relative to the file that holds
it, so one in a gem's changelog starts with `../../`.

Release notes explain why an upgrader should care and what action is needed.
Link the detailed changelog instead of repeating it. Internal refactors and
branch history belong in commits unless they affect users.
