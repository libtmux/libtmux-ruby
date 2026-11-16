# version-check

Runs the test that shows the library refusing an unsupported tmux release.

[`ci-matrix.json`](../ci-plan/ci-matrix.json) gives each refused release a
check. The `unsupported` job in
[`compatibility.yml`](../../.github/workflows/compatibility.yml) builds that
tmux as the daemon, installs a supported tmux as the client, and passes the
check and the release here.

| Check | Test | Expects |
| --- | --- | --- |
| `old_daemon` | [`pre_3_2_refusal_test.rb`](../../test/old_daemon/pre_3_2_refusal_test.rb), stopped after 120 seconds | The release itself, 3.0a or 3.1c |
| `refused` | [`tmux_version_check_test.rb`](../../test/integration/tmux_version_check_test.rb) | `refused` |

The script exits 1 and names the release when no test is assigned to a check.
`LIBTMUX_TEST_TMUX` names the daemon and `LIBTMUX_VERSION_CHECK_CLIENT_TMUX` a
client at tmux 3.3a or newer, and both pass through to the test.

## Tests

[`tests/`](tests) check that every check the manifest allows has a test file,
the environment and deadline each check gets, the exit status of an unknown
check, and that a test past its deadline stops with status 124.

```console
$ bundle exec scripts/check unit scripts/version-check/tests/version_check_test.rb
```
