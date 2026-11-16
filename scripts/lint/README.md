# lint

Formats and lints the Ruby scripts with [Standard](https://github.com/standardrb/standard),
RuboCop with a fixed rule set. `scripts/check mid` and `scripts/check outer` run
it over every Ruby script under `scripts/`, found by extension or shebang.

`.standard.yml` holds the one exception: `scripts/bench` rescues `Exception` to
record any failure, Interrupt included, and re-raise it.

```console
$ bundle exec scripts/lint/lint
```

Name files to check only those. The exit status is Standard's, so a violation
fails `scripts/check`. `bundle exec standardrb --fix` rewrites the safe ones.

## Tests

```console
$ bundle exec scripts/check unit scripts/lint/tests/lint_test.rb
```

The tests pass the repository's scripts and a clean file, and require a file
with a violation to fail and name its rule.
