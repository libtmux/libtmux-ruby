# Guide

Use the blocking core for scripts, the Async adapter for a service that must
keep reading while commands wait, and MCP or workspace when the caller works
through a protocol or configuration document.

- [Execution modes](modes.md): blocking calls, Async tasks and control subscriptions.
- [Ownership and errors](ownership-errors.md): what close, cancel and failure mean.
- [Executable recipes](recipes.md): complete programs with excerpts.
- [Field catalog](reference/fields.md): query fields and wire names.
- [Public methods](reference/api.md): each exported method, its source and contract.
- [Public behavior](reference/behavior.md): I/O, ownership, defaults and failure.
- [Benchmarks](benchmark.md): workloads and measurements.
- [README](../README.md): install, quick start and what it leaves out.
- [Releasing](releasing.md): version preparation and trusted publishing.
