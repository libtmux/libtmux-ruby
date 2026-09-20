# Guide

Use the blocking core for scripts, the Async adapter for a service that must
keep reading while commands wait, and MCP or workspace when the caller works
through a protocol or configuration document.

- [Execution modes](modes.md) compares scheduling and result evidence.
- [Ownership and errors](ownership-errors.md) explains what close and failure mean.
- [Executable recipes](recipes.md) links complete programs with checked excerpts.
- [Field catalog](reference/fields.md) lists generated metadata and wire names.
- [Public methods](reference/api.md) maps exported methods to source, returns and contracts.
- [Public behavior](reference/behavior.md) specifies I/O, ownership, defaults and failure evidence.
- [Benchmarks](benchmark.md) describes equal workloads, raw evidence and open comparison gates.
- [Project entry point](../README.md) covers local installation and current gaps.

The rendered site also includes a YARD declaration tree. The public-method
inventory checks source links, declaration visibility and behavioral mappings.
Installed signature consumers check selected real arguments, blocks and return
values against RBS. Their output lists the exercised methods; this does not
establish whole-program static typing or full overload coverage.
