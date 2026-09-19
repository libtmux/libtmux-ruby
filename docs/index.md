# Guide

Use the blocking core for scripts, the Async adapter for a service that must
keep reading while commands wait, and MCP or workspace when the caller works
through a protocol or configuration document.

- [Execution modes](modes.md) compares scheduling and result evidence.
- [Ownership and errors](ownership-errors.md) explains what close and failure mean.
- [Executable recipes](recipes.md) links complete programs with checked excerpts.
- [Field catalog](reference/fields.md) lists generated metadata and wire names.
- [Project entry point](../README.md) covers local installation and current gaps.

The rendered site includes a separate YARD API tree. Its declarations and
short comments do not yet provide the complete behavioral contract for every
public method. RBS validates shipped declarations; it does not type-check the
implementation.
