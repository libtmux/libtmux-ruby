# libtmux for Ruby

Create tmux sessions, address panes by assigned IDs, and capture topology for
local queries. The repository contains four independently buildable,
unreleased gems. Imports do not start tmux, a scheduler or a protocol server.

| Use | Gem and import | Execution model |
| --- | --- | --- |
| Scripts | `libtmux`, `require "libtmux"` | Blocking commands, captured queries and control connections |
| Event-driven services | `libtmux-async`, `require "libtmux/async"` | Caller-owned Async tasks and bounded streams |
| Protocol tools | `libtmux-mcp`, `require "libtmux/mcp"` | Official MCP SDK with explicit endpoint and tool policy |
| Workspace configuration | `libtmux-workspace`, `require "libtmux/workspace"` | Inert YAML/JSON plans, explicit apply and CLI |

The [list and filter program](examples/list_filter.rb) creates its own isolated
server and checks that a captured query remains local after the server closes.
This excerpt runs inside its cleanup wrapper:

<!-- example: list_filter/main -->
```ruby
session = server.new_session(name: "capture", command: ["/bin/cat"])
session.new_window(name: "second", command: ["/bin/cat"])
snapshot = server.snapshot
panes = snapshot.panes
first = panes.one(id: panes.first.id)
session.new_window(name: "later", command: ["/bin/cat"])
Example.check(panes.size == 2, "captured membership changed")
Example.check(panes.where(id: first.id).one.ref == first.ref, "wrong exact match")
Example.raises(LibTmux::MultipleMatchesError) { panes.one }
Example.check(panes.one_or_nil(id: "%4294967294").nil?, "missing pane was invented")
```
<!-- /example -->

The examples require installed local gem artifacts and an installed `tmux`.
Run the complete program after installing the core artifact:

```console
$ ruby examples/list_filter.rb
```

Build artifacts with the development bundle:

```console
$ mise exec -- bundle exec rake build
```

Install the core artifact locally:

```console
$ gem install \
    --local \
    --no-document \
    pkg/libtmux-0.1.0.pre.gem
```

The version is an unreleased development version; no registry release is
claimed. Companion gems require their declared runtime dependencies. The
offline [packaging check](.github/CONTRIBUTING.md#checks) builds all artifacts,
installs each dependency closure into temporary gem homes, and runs every
recipe outside the checkout.

Read [the guide](docs/index.md), [execution modes](docs/modes.md),
[ownership and errors](docs/ownership-errors.md), and
[executable recipes](docs/recipes.md). The generated
[field catalog](docs/reference/fields.md) documents criteria wire names and
null decoding. Package notes cover [core](gems/libtmux/README.md),
[Async](gems/libtmux-async/README.md), [MCP](gems/libtmux-mcp/README.md),
and [workspace](gems/libtmux-workspace/README.md).

Development uses the Ruby in [.tool-versions](.tool-versions).
[Compatibility CI](https://github.com/libtmux/libtmux-ruby/actions/workflows/compatibility.yml)
requires Ruby 3.3.12, 3.4.10 and 4.0.7 on Linux and macOS, each with tmux
3.2a, 3.3a, 3.4, 3.5a, 3.6 and 3.7c. Consult the results for the revision
being used; a passing subset does not establish the full matrix. Tracked MCP
captures, waits and authored runs require tmux 3.3+ and native process identity.
Workspace `--switch CLIENT` accepts
an explicit current native client selector after creation; it does not claim
a historical client incarnation. The
[public method inventory](docs/reference/api.md) links exported methods to
source, declared returns and behavioral contracts. Installed
signature consumers exercise selected real calls; they do not establish
whole-program static typing. [Benchmarks](docs/benchmark.md) record workload
equivalence, measured costs and resource cleanup with explicit measurement
limits. Packages are unreleased and release automation is not provided.

See [Contributing](.github/CONTRIBUTING.md) for setup and checks. This project
uses the [MIT license](LICENSE).
