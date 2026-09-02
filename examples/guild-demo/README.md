# A Guild's First Day — the Sub-project 6 Demo

A single-HTML-file, RPG-tutorial-styled walkthrough of what Riptide's derivation and execution
layer (Sub-project 6) ships: teaching real WASM Capabilities, watching WASI trap a fault cleanly,
anti-unification learning a pattern from two similar Tasks (and recognizing when a "new" one
teaches nothing it doesn't already know), cross-tenant discovery and installation with Crosswalk
auto-mapping, mutex-exclusive concurrent Tasks, and the generic `/query` endpoint.

Chapter 6 doesn't demonstrate a live recursive/fixpoint derivation — confirmed during
implementation that this isn't reachable through this demo's own real-HTTP-only constraints (see
`docs/superpowers/plans/2026-09-02-phase-6p-iii-demo-page.md`'s own Task 7 notes): there's no
self-service HTTP endpoint for admitting a hand-authored Rule at all (an explicit non-goal of the
6p-i design), and the every tenant this demo can construct via HTTP already has a Capability-shaped
Rule admitted, which `POST /query` refuses to evaluate by design. Chapter 6 shows the real endpoint
honestly instead, on a fresh tenant with an empty ruleset.

## Prerequisites

1. A running Riptide instance (`mix phx.server` from the repo root, or equivalent), reachable from
   whatever browser opens this page.
2. **An LLM API key configured on that instance** — set `LLM_API_BASE_URL`, `LLM_API_KEY`, and
   `LLM_API_MODEL` in its environment before booting it. Chapters 1-4 each resolve at least one
   Task through this. Any OpenAI-compatible endpoint works (see `docs/superpowers/specs/`
   phase 6r) — no specific vendor required.
3. `wasmtime` on the server's own `PATH` — Chapters 1, 2, and 5 invoke real WASM Capabilities.

## Running it

Open `index.html` directly in a browser (double-click it, or `file://` the path) — no server, no
build step. Enter your Riptide instance's base URL (defaults to `http://localhost:4000`) and click
Begin.

Clicking through the whole demo drives more writes against Guild A's own tenant than
`Riptide.WriteRateLimit`'s default of 10/minute allows if done quickly — a human clicking through
at a normal pace over several minutes won't hit this, but running the whole thing back-to-back
might. Set `WRITE_RATE_LIMIT` higher in the server's own environment if that happens (see
`config/dev.exs`).

## Verifying it

`smoke-test.mjs` drives the entire seven-Chapter flow end-to-end via Playwright, backed by a mock
LLM server (`mock-llm-server.mjs`) so it's runnable without a real API key or non-deterministic
output:

```bash
npm install   # first run only — installs Playwright locally for this directory
node smoke-test.mjs
```

This is standalone tooling, not part of `mix test`/CI — it boots its own `mix phx.server` (with
`WRITE_RATE_LIMIT` already raised and `wasmtime` already on `PATH`) and mock LLM server, and tears
both down when it finishes.
