# Riptide

Riptide is the reference implementation of **StreamLD**, a clean-slate, professional-grade
standard for real-time-capable Linked Data event streaming — incubating within the
[OpenFASTER](https://openfaster.org) ecosystem.

Riptide is an Elixir/Phoenix server that speaks enough Solid/LDP to act as a usable pod
server, backed natively by a StreamLD event log instead of a request/response pipeline —
an event-driven alternative to [Community Solid Server](https://github.com/CommunitySolidServer/CommunitySolidServer).

Design status: architecture approved, not yet implemented. See
`docs/superpowers/specs/2026-08-22-streamld-riptide-design.md` for the full design and its
rationale.

The StreamLD specification itself lives in a separate repo:
[`OpenFASTER-Standard/spec`](https://github.com/OpenFASTER-Standard/spec).
