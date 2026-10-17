# Migration

## tmux 3.3a minimum

The suite requires tmux 3.3a or newer. Unpatched 3.3 is below the minimum.
`Server.open`, `Server.new` and `Server.start` raise `UnsupportedFeatureError`
for an older daemon or executable before any requested command runs. The
connected daemon decides, so a newer client does not accept an older daemon.
Update the daemon, or point the endpoint at a supported one.

`Server.new` and `Server.open` now read the daemon release while they
construct, which blocks for up to `version_timeout:` seconds (default five).
A socket with no listening daemon raises `TargetNotFoundError` at that point
instead of at the first command.

## PaneSnapshot#pid may be nil

`PaneSnapshot#pid` returns `Integer?` on every tmux release, and the `where`
schema accepts `null` for `pid`. Only a dead pane on tmux 3.8 reports an empty
`#{pane_pid}`; earlier releases keep returning an integer, so existing callers
see no change at runtime on them. Typed consumers need to handle `nil`:

```ruby
pid = pane.pid
process = Process.kill(0, pid) if pid
```

MCP process tracking of a pane without a PID raises `TargetNotFoundError`.
