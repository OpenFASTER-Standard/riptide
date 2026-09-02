# Phase 6p-ii — Demo WASM Components

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. Phase 6p is the
Sub-project 6 demo — a single-HTML-file, RPG-tutorial-styled walkthrough ("a guild's first day") meant
to show off everything Sub-project 6 has actually built, running self-bootstrapped against a genuinely
fresh Riptide instance. It was split into three independent sub-phases during brainstorming (mirroring
the 6h-i/6h-ii and 6c-i-a/6c-i-b decomposition pattern already used elsewhere in this sub-project):

- **6p-i — Backend additions** (`mutex_key` rename/threading + the new query endpoint). **Shipped
  2026-09-02** — see `docs/superpowers/specs/2026-09-01-phase-6p-i-demo-backend-additions-design.md`.
- **6p-ii — Demo WASM components** (this phase). Pure Rust/WASM, independently buildable and testable,
  no dependency on 6p-i.
- **6p-iii — The demo page itself.** Depends on both 6p-i and 6p-ii.

This phase hand-authors the two real WASM Capability components the demo's narrative requires. Nobody
else will produce these, and 6n's own spec explicitly named and deferred "convenient WASM component
authoring/production tooling" as separate follow-up work — so, same as the one existing precedent in
this codebase (`test/fixtures/riptide_capability/fixture.wasm`, hand-built for 6b-i's own test suite),
these get hand-written WIT worlds + Rust source, built via `cargo component build --release`, and
checked into the repo as binary artifacts with a documented rebuild recipe.

## 2. The full six-beat narrative (for reference — not all of it is this phase's concern)

Reconstructed here in full because beats 1 and 2 are what actually motivate this phase's two
components; beats 3-6 are included for narrative continuity/context only and are 6p-iii's concern.

1. **Teach Riptide its first trick.** Propose+approve a real WASM Capability (**the badge/QR-code
   generator**, this phase's first component), *then* submit a Task that needs it — LLMFallback picks
   the just-taught capability. Fixed from an earlier draft: capabilities must be taught *before* any
   Task can use them, since a fresh instance starts with zero capabilities.
2. **Teach it a second, deliberately-broken capability** (this phase's second component), then a
   follow-up Task that resolves to it via LLMFallback — WASI sandboxing traps the fault cleanly, live,
   not a crash/hang.
3. **The system learns a pattern.** A second similar Task (still LLMFallback) triggers an
   anti-unification proposal — show the two traces, the generalized template, the fidelity pass/fail
   evidence, approve it live. A third similar Task now resolves via Discovery — instant, zero LLM call;
   the speed contrast is the payoff.
4. **Two guilds, shared knowledge.** Guild B is bootstrapped live on-screen with its own pre-existing
   local convention (its own differently-named predicate for the same concept, e.g. `guildB:awardedBadge`
   vs. Guild A's own predicate) *before* any Hub interaction, so the later Crosswalk translation is real
   and visible, not vacuous. Guild A publishes its admitted pattern to the Hub; an unauthenticated "Hub
   Browser" pane (second tab) watches it appear live via SSE on `GET /hub/resources/*path`. Guild B
   discovers+installs it; Crosswalk auto-maps matched fields and flags unmatched ones for manual
   confirmation. Guild A then proposes a v2 of the Capability with `"replaces"`, approves it; Hub Browser
   shows v1 flip to "superseded" with full history still viewable.
5. **Two players, one chest.** Two same-`mutex_key`-tagged Tasks fired simultaneously against a
   capability with a deliberate few-second processing delay, shown as two timestamped start/end bars on
   a shared timeline — one only starts after the other ends, never overlapping. Phrased as "no
   double-loot," not "serialize" (flagged during brainstorming as unclear jargon). Ships in 6p-i.
6. **Ask a question, not just store data.** A skill-tree/guild-hierarchy example exercising
   recursive/fixpoint rule evaluation live, via 6p-i's new query endpoint.

Asides folded in rather than standalone acts (6p-iii's concern, not new backend/component work):
bitemporal storage (raw Turtle annotation reveal), rules-as-facts ("peek at the data"), blob/dedup
content-addressing, supervised-process guarantees.

Act 0 (the page's own bootstrap — real signup calls against 6o's shipped `POST /auth/signup` to claim
Guild A's tenant and create Alice's real account, and similarly for Guild B's own later bootstrap in
beat 4) is also 6p-iii's concern, not this phase's.

## 3. Scope of this phase

Two hand-authored WASI Preview 2 components, each: a WIT world + Rust source (following
`test/fixtures/riptide_capability/README.md`'s existing documented recipe), built with
`cargo component build --release`, checked into the repo as a `.wasm` binary artifact with its own
README documenting the exact rebuild steps (mirroring that existing fixture's own README format).

1. **The badge/QR-code generator** — an `EffectCapability` used in beat 1.
   `generate-qr-code(text: string) -> string`. `text` is the visitor's own free-text content (e.g. "make
   a QR code that says X"), extracted from the Task's natural-language submission by LLMFallback's
   existing arg-extraction mechanism — not a fixed/canned string. Returns a self-contained SVG string:
   directly embeddable in the demo page, and avoids needing any PNG/image-codec crate to compile against
   `wasm32-wasip2` (raster output would carry real crate-compatibility risk that SVG output sidesteps).
2. **The deliberately-broken component** — used in beat 2 to demonstrate WASI sandboxing trapping a
   fault live. `curse() -> ()` (no-arg, mirrors `burn-fuel()`'s own shape) — calls `panic!(...)`
   immediately. Deliberately *not* a reuse of the existing test fixture's `burn-fuel()` mechanic: per
   `Riptide.Capability.classify_result/2` (`lib/riptide/capability.ex:100-107`), an infinite loop only
   ever produces `{:error, :resource_exhausted}` by waiting out the fuel/timeout window (closer to a
   hang than a clean trap), whereas an immediate panic produces `{:error, {:trap, output}}` within
   milliseconds — matching beat 2's own framing ("traps the fault cleanly, live, not a crash/hang") far
   better. `{:trap, _}` is also currently unexercised by any real invocation anywhere in this codebase
   (confirmed via `grep -rn "{:trap" test/ lib/` — only referenced in an explanatory comment), a
   secondary but real benefit.

Both components are registered into the demo via the existing, unchanged Capability propose/approve
flow (`DedupGate.propose_capability/3` + `Hub.CapabilityController`/`Catalog.admit_capability/2`, all
shipped in 6k/6n) — no new registration mechanism, this phase only produces the component bytes
themselves. Since there is no live in-browser WASM-authoring mechanism, beat 1's "propose+approve a real
WASM Capability" step is a literal file upload of this phase's pre-built `.wasm` artifact through that
existing base64-body propose flow — the actual upload widget/interaction is 6p-iii's concern, not this
phase's.

**File locations.** `test/fixtures/riptide_capability` is a *test* fixture location, not appropriate for
demo assets, and 6p-iii (the demo page itself, which will actually reference these files) hasn't been
brainstormed yet, so no `examples/` directory for it exists today. This phase creates
`examples/guild-demo/capabilities/`, anticipating 6p-iii's own working title from brainstorming ("a
guild's first day") — trivially renameable via `git mv` if 6p-iii picks a different top-level name, not
a design blocker. Each component gets its own subdirectory, mirroring the existing fixture's own
directory-per-component shape (a README plus the binary artifact, no checked-in buildable Rust
project — same "recipe documented in prose, not a live crate" precedent):
`examples/guild-demo/capabilities/badge-qr-generator/{README.md,badge-qr-generator.wasm}` and
`examples/guild-demo/capabilities/curse/{README.md,curse.wasm}`.

## 4. Non-goals

- **Convenient WASM component authoring/production tooling** — explicitly deferred by 6n's own spec as
  separate follow-up work; this phase hand-authors two specific components the same manual way the one
  existing fixture was built, it does not build tooling to make that easier in general.
- **The demo page itself, beats 3-6, and Act 0** — 6p-iii's concern.
- **A new Capability registration mechanism** — both components go through the existing, unchanged
  propose/approve flow.

## 5. Resolved decisions (were open questions, settled during brainstorming)

- **Badge/QR-code generator encodes visitor-supplied free text, not a fixed URL.** Reconciles the
  earlier `examples/live-story`-tied framing (`generate-qr-code(line_url) -> image`) with the
  guild/badge narrative: `text` comes from the Task's own natural-language submission via LLMFallback's
  existing arg-extraction, and the return type is a self-contained SVG string (§3, item 1).
- **The broken component traps immediately via `panic!()`, not a fuel-exhaustion hang.** Deliberately
  different from the existing test fixture's `burn-fuel()` mechanic — grounded in
  `Riptide.Capability.classify_result/2`'s actual two-branch behavior (`:resource_exhausted` vs.
  `{:trap, output}`), not just "something different" (§3, item 2).

## 6. Build environment and end-to-end validation (confirmed live, 2026-09-02)

Both components were actually built and run on this box before finalizing this design — not assumed
from reading crate docs.

- **Environment setup performed**: `rustup target add wasm32-wasip2` (previously absent — only
  `wasm32-unknown-unknown`/`x86_64-unknown-linux-gnu` were installed) and `cargo install cargo-component
  --version 0.21.1` (previously absent), matching the existing fixture README's own pinned version. Both
  are now installed system-wide, same as this box's other pinned toolchains. `cargo-component build`
  itself still targets `wasm32-wasip1` under the hood (the existing fixture README's own recipe shows
  the same — a `cargo-component` quirk, not a version mismatch), so `wasm32-wasip1` gets installed as a
  side effect of the first build.
- **QR generator: built and run successfully.** `qrcode = { version = "0.14.1", default-features =
  false, features = ["svg"] }` (explicitly *not* the default `image`/`pic` features — avoids pulling a
  raster-image-codec dependency chain into the component for no benefit, since only SVG output is
  needed) compiles cleanly under `cargo-component build --release` and produces a working
  `.wasm`. Invoked directly via `wasmtime run -W component-model=y --invoke
  'generate-qr-code("hello-riptide")' ...wasm` (the exact mechanism `Riptide.Capability.run_wasmtime/1`
  uses) and returned a well-formed, valid SVG string.
- **Curse component: built and run successfully, confirmed correct failure classification.** `panic!(...)`
  inside the exported `curse()` function produces exit status 134 and output containing `wasm trap: wasm
  \`unreachable\` instruction executed` plus the Rust panic message — none of the three substrings
  `Riptide.Capability.classify_result/2` checks for `:resource_exhausted` ("all fuel consumed",
  "interrupt", "exceeds memory limits") appear, so this is confirmed to land in the `{:error, {:trap,
  output}}` branch exactly as designed (§3, item 2), not assumed from reading the classifier's source
  alone.

## 7. Testing

- Direct component invocation via the existing Capability test patterns (`Riptide.Capability`'s own
  test suite, confirmed to already support directly invoking an arbitrary `.wasm` fixture by path/hash)
  — both components get success-path and (for the broken one) failure-path coverage this way, without
  needing the full HTTP/DedupGate/propose-approve flow to exercise the component itself. The QR
  generator's success-path test asserts the returned string parses as well-formed SVG (not a byte-exact
  golden match, which would be brittle against `qrcode` crate version bumps); the curse component's
  failure-path test asserts `Riptide.Capability.invoke/4` returns `{:error, {:trap, _}}` specifically
  (not just any non-`:ok` result), to actually pin the failure-mode distinction §3 is built on.
