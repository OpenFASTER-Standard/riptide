# Phase 6p-iii — The Sub-project 6 Demo Page

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. Phase 6p is the
Sub-project 6 demo — a single-HTML-file, RPG-tutorial-styled walkthrough ("a guild's first day")
meant to show off everything Sub-project 6 has actually built, running self-bootstrapped against a
genuinely fresh Riptide instance. It was split into three independent sub-phases during
brainstorming:

- **6p-i — Backend additions** (`mutex_key` rename/threading + the query endpoint). Shipped
  2026-09-02.
- **6p-ii — Demo WASM components** (the badge/QR-code generator, the deliberately-broken
  component). Shipped 2026-09-02.
- **6p-iii — The demo page itself** (this phase). Depends on both.

**Direct origin of this spec.** Brainstorming this phase resumed after Phase 6q (Tenant Sovereignty)
shipped — 6q was itself triggered by a question raised while first attempting to brainstorm 6p-iii
("mustn't a Hub Browser be scoped to a tenant?"), which led to eliminating the global `:hub` scope
entirely. This phase's own Chapter 4 (originally "two guilds, shared knowledge," staged around a
Hub Browser pane watching a global SSE stream) is redesigned here against 6q's actual shipped
model, not the pre-6q one the original six-beat narrative assumed.

A second dependency surfaced mid-brainstorm: `Riptide.Derivation.LLMFallback`'s only client
implementation was hardcoded to Anthropic's own API. Since this phase's docs need to describe the
LLM prerequisite without naming a vendor, and the underlying `Client` behaviour already existed
specifically to be pluggable, this was fixed as its own phase (6r — Generic OpenAI-Compatible LLM
Client, shipped 2026-09-02) before this spec was finished.

**Terminology.** The original brainstorming called the demo's six narrative sections "beats" —
screenwriting jargon that reads oddly in a player-facing quest log. This spec calls them
**Chapters** throughout (Chapter 0 is the bootstrap, Chapters 1-6 are the narrative arc), matching
the RPG-tutorial framing and the "quest log" sidebar the page itself uses.

## 2. Scope

A single self-contained HTML file (`examples/guild-demo/index.html`) — HTML structure, CSS (a
lightweight parchment/quest-log theme, no external font/asset dependency), and vanilla JS (no build
step) — that a visitor opens directly (`file://`) and steps through seven Chapters (0-6), each
performing real HTTP calls against a live Riptide instance and rendering the real response. No new
backend code; every endpoint this phase calls already exists (6p-i, 6k/6n's propose/approve flow,
6q's tenant/discovery/install surface, 6c-ii's query endpoint).

Also in scope: `examples/guild-demo/README.md` (prerequisites, how to open, what each Chapter
shows) and `examples/guild-demo/smoke-test.mjs` (a standalone Node+Playwright script driving the
full seven-Chapter flow end-to-end, run on demand — not part of `mix test`/CI, since it needs a
live LLM API key and a running dev server, neither available there).

## 3. Non-goals

- **A build step, bundler, or npm dependency for the page itself.** The only external dependency is
  N3.js, loaded via a CDN `<script>` tag (§4.6) — everything else is plain JS/CSS/HTML in one file.
- **A backend LLM stub/demo mode.** Explicitly decided during brainstorming: Chapters 1-3 depend on
  a real, already-configured LLM API key on the Riptide instance being demoed against — documented
  as a prerequisite (§4.1), not worked around.
- **Resuming an in-progress demo run across a page reload.** Every run mints brand-new tenants
  (fresh UUIDs); a reload simply restarts at Chapter 0. No `localStorage`/session persistence.
- **General cross-tenant discovery of unknown tenants**, or anything else 6q's own spec already
  scoped out — this phase only exercises what 6q shipped, it doesn't extend it.
- **An automated `mix test` / ExUnit test suite for the page.** Verification is the Playwright
  smoke test (§7), run manually — this is a demo artifact, not production code, and every backend
  behavior it exercises already has its own ExUnit coverage.

## 4. Detailed design

### 4.1 Prerequisites (documented in `README.md`, checked live in Chapter 0)

- A running Riptide instance (`mix phx.server` or equivalent), reachable from the browser opening
  this HTML file. CORS is already wide open (`RiptideWeb.Endpoint`'s `CORSPlug`, wildcard origin, no
  credentials) — no server-side change needed to allow this.
  - **This is the demo's single-source-of-configuration**: the page has no way to detect other
    prerequisites (e.g. a missing LLM API key) except by trying — see §6's `llm_fallback_failed`
    handling.
- **An LLM API key configured on that instance** (`LLM_API_BASE_URL`/`LLM_API_KEY`/
  `LLM_API_MODEL` env vars, per 6r) — required for Chapters 1-3, which all resolve at least one Task
  via LLMFallback. Never named as a specific vendor anywhere in this page's own copy or docs.

### 4.2 Page structure

A fixed left sidebar lists all seven Chapters (0-6) as a quest log — completed ones checked off,
the current one highlighted, later ones visible but visually inactive (not clickable ahead of
turn). The main panel renders only the current Chapter: its own instructions, one or more action
buttons, and a results area that fills in as each action's response arrives. A "Next chapter →"
button appears once the current Chapter's own payoff has rendered (defined per-Chapter in §4.4-4.9)
— never before, so the visitor can't skip past an incomplete demonstration.

```html
<div id="app">
  <nav id="quest-log"><!-- Chapter 0-6 list, populated by JS --></nav>
  <main id="chapter-view"><!-- current Chapter's own template --></main>
</div>
```

### 4.3 State model

One flat, mutable JS object, `state`, initialized empty at page load and populated in place as
Chapters complete:

```js
const state = {
  baseUrl: null,          // set in Chapter 0
  guildA: { tenantId: null, aliceToken: null, aliceSub: null },
  guildB: { tenantId: null, bobToken: null, bobSub: null },
  chapter1: { capabilityNodeId: null, jobNodeId: null },
  chapter2: { capabilityNodeId: null, jobNodeId: null },
  chapter3: { secondJobNodeId: null, patternNodeId: null, thirdJobNodeId: null },
  chapter4: { guildBLocalRuleNodeId: null, discoveredNodeId: null, installReviewNodeId: null, v2PatternNodeId: null },
  chapter5: { job1NodeId: null, job2NodeId: null },
  chapter6: { ruleNodeId: null },
};
```

Every Chapter's own module reads whatever prior state it needs directly off this object and writes
its own results back onto it — no threading of return values between Chapter functions, matching
the demo's own linear, single-session nature (there is exactly one "current run" at a time, never
concurrent independent runs sharing one page load).

### 4.4 Chapter 0 — Bootstrap

- An input for the API base URL (default `http://localhost:4000`, editable) plus a "Begin" button.
- "Begin" calls `POST {baseUrl}/auth/signup` with
  `{"name": "guild-a", "username": "alice", "password_hash": sha256hex("guild-demo-pw")}` —
  the fixed demo password is hashed client-side via `crypto.subtle.digest("SHA-256", ...)`,
  hex-encoded to match the backend's own expectation (`RiptideWeb.Auth.SignupController`'s
  `@password_hash_pattern`). Stores `state.baseUrl`, `state.guildA.tenantId`,
  `state.guildA.aliceToken` from the `200` response
  (`{"token", "sub", "tenant_id"}` per 6q's shipped `SignupController`). Also stores
  `state.guildA.aliceSub` from the same response.
- Payoff: a short "Welcome, Alice of Guild A" confirmation renders; "Next chapter" advances to
  Chapter 1.

### 4.5 Chapters 1 and 2 — Teach + use a Capability

Structurally identical (Chapter 2 additionally being about a Capability that panics), so specified
together — differences called out inline.

**Teach step:**
- A `<input type="file" accept=".wasm">` — help text names the expected file
  (`capabilities/badge-qr-generator/badge-qr-generator.wasm` for Chapter 1,
  `capabilities/curse/curse.wasm` for Chapter 2 — both relative to this HTML file's own location,
  matching 6p-ii's checked-in layout) — plus a "Teach this capability" button.
- Reads the selected file via `FileReader.readAsArrayBuffer`, base64-encodes it
  (`btoa(String.fromCharCode(...new Uint8Array(buf)))`), and calls
  `POST {baseUrl}/tenants/{guildA.tenantId}/capabilities` with:
  - Chapter 1: `{"name": "urn:riptide:capability:guild-demo-badge", "kind": "effect", "function": "generate-qr-code", "fuel_limit": 100000000, "timeout_ms": 5000, "memory_limits": {...all null...}, "component_bytes": "<b64>"}`
  - Chapter 2: same shape, `"name": "urn:riptide:capability:guild-demo-curse"`,
    `"function": "curse"`.
- Stores the `node_id` from the `200` response into `state.chapterN.capabilityNodeId`, then
  immediately calls `POST .../capability-reviews/{node_id}/approve`.
- Payoff (of the teach step): "✓ Taught" badge renders; a "Use it" section appears below.

**Use step:**
- A free-text field, visitor-editable, pre-filled with a suggested default (Chapter 1: `"make a
  badge that says Welcome, Adventurer!"`; Chapter 2: `"try the cursed amulet"`) plus a "Submit
  Task" button.
- Calls `POST {baseUrl}/tenants/{guildA.tenantId}/tasks` with `{"description": "<text>"}`, storing
  the returned `job_node` into `state.chapterN.jobNodeId`.
- Subscribes via `subscribeStream(job_stream_id, aliceToken, onPatch)` (§4.6) to
  `{baseUrl}/tenants/{guildA.tenantId}/resources/jobs`'s own stream, filtering incoming patch quads
  by the known job blank-node id, until that Job's `jobStatus` triple reads `"done"` (Chapter 1) or
  `"failed"` (Chapter 2).
- Payoff — **Chapter 1**: the Job's `jobResult` literal (the SVG string LLMFallback resolved and
  the badge Capability returned) is injected directly into the DOM (`innerHTML`) as a rendered
  image — the QR badge, live.
- Payoff — **Chapter 2**: a "the curse backfires!" framed panel renders the Job's own `jobError`
  literal (containing the `{:trap, output}` detail `Capability.classify_result/2` produced),
  explicitly captioned "WASI caught the fault cleanly — no crash, no hang, just a clean trap."

### 4.6 Data-access helpers (used from Chapter 1 onward)

Loaded via `<script src="https://unpkg.com/n3/browser/n3.min.js"></script>` (the one external
dependency this page has, per brainstorming's own decision to use a real Turtle parser rather than
hand-rolled extraction).

```js
async function fetchTurtle(path, token) {
  const res = await fetch(state.baseUrl + path, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  if (!res.ok) throw new HttpError(res.status, await res.text());
  const text = await res.text();
  const store = new N3.Store();
  store.addQuads(new N3.Parser().parse(text));
  return store;
}

function subscribeStream(streamId, token, onPatch) {
  const url = `${state.baseUrl}/streams/${encodeURIComponent(streamId)}/subscribe?token=${token}`;
  const es = new EventSource(url);
  es.onmessage = (ev) => onPatch(new N3.Parser().parse(ev.data));
  return es; // caller closes via es.close() once its own condition is met
}

async function postJson(path, token, body) {
  const res = await fetch(state.baseUrl + path, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new HttpError(res.status, text);
  // Some endpoints (e.g. .../capability-reviews/:id/approve) reply 200 with an empty body, not
  // JSON — read as text first, and only parse if there's actually something there, rather than
  // guessing from status code or content-length.
  return text === "" ? null : JSON.parse(text);
}
```

Riptide's own Job/Capability/Rule vocabulary IRIs (`urn:riptide:vocab:jobStatus`, etc.) are
inlined as JS constants alongside these helpers, mirroring the exact terms each backend RDF codec
(`JobRDFCodec`, `CapabilityCatalogRDFCodec`, etc.) already writes — this page reads the same wire
format those codecs produce, not a separate summary format.

**Correlating a parsed blank node with a `node_id` string.** Some endpoints return a `node_id` as
plain JSON (e.g. `POST /capabilities`'s own `{"node_id": "..."}`); others (discovery search,
`GET /resources/*`) return only Turtle, with the same node addressed as a blank-node subject
(`_:b0`). These are the same identifier in both forms: a Turtle blank node's own label round-trips
verbatim through `TurtleCodec.encode/1` → wire Turtle → `N3.Parser` (`_:b0` parses to a blank node
whose `.value` is `"b0"`, exactly what the server's own `RDF.BlankNode.value/1` returns — the same
contract this codebase's own test suite already relies on server-side,
e.g. `RDF.BlankNode.value(node) == node_id`). So Chapter 4's discovery step (§4.8) finds the
matching Rule's own subject quad in the parsed store and uses `quad.subject.value` directly as the
`node_id` string for the subsequent install call — no separate lookup or ID-mapping step needed.

### 4.7 Chapter 3 — The system learns a pattern

- A second Task submission, same free-text-with-default UI as Chapter 1's use step, deliberately
  phrased close to Chapter 1's own (e.g. `"make a badge that says Great job, Champion!"`) —
  resolves via LLMFallback again (Discovery has nothing to match yet), its own Job watched to
  completion the same way. Stores `state.chapter3.secondJobNodeId` for this Task — Chapter 1's own
  already-completed Job is already sitting in `state.chapter1.jobNodeId`, reused directly below.
- "Propose this as a pattern" button: `POST {baseUrl}/tenants/{guildA.tenantId}/propose` with
  `{"job1": chapter1.jobNodeId, "job2": chapter3.secondJobNodeId}`. The response itself only
  carries `{"outcome", "kind", "node_id"}` — no trace/template/evidence content — so immediately
  after, calls `fetchTurtle('/tenants/{guildA.tenantId}/resources/catalog/pending-review',
  aliceToken)` (§4.6) to read the *same* pending-review data `Catalog.list_pending_reviews/1`
  already exposes as a library function, addressed via the ordinary generic LDP resource-read path
  — `Catalog.pending_review_stream_id/1` and `ResourceController.stream_id_for/2` construct the
  identical stream id for this path, and `show/2`'s own GET handler never applies the
  reserved-path check that only blocks writes, so this already works today with zero new backend
  code. Finds the blank node matching the just-returned `node_id`, extracts its candidate Rule text
  and fidelity-evidence quads via N3 queries on the parsed store, and renders both. Stores the
  review's own `node_id` into `state.chapter3.patternNodeId`.
- "Approve" button on the resulting review —
  `POST .../pending-reviews/{chapter3.patternNodeId}/approve`.
- A third Task submission (same phrasing family, stored as `state.chapter3.thirdJobNodeId`) — its
  `202` response's own `resolved_via` field now reads `"discovery"` instead of `"llm_fallback"`.
  Payoff: the three Tasks' own `resolved_via` values render side by side, landing the
  speed-contrast point directly (no artificial timer needed — the *mechanism* that resolved each
  one is the visible payoff, not wall-clock time, which an LLM call's own latency variance would
  make an unreliable thing to showcase precisely).

### 4.8 Chapter 4 — Two guilds, shared knowledge

Restaged against 6q's shipped model — no Hub Browser, no global stream. "Publishing" is Guild A
admitting into her own Catalog and granting a `:public` read policy; "discovery" is Guild B calling
the real tenant-name-resolution + discovery-search endpoints; the "watch it happen live" pane is
Guild A's *own* now-publicly-readable catalog stream, not a separate global one.

**What gets shared is Guild A's own Chapter-3 pattern** — the generalized Rule anti-unification
produced (`state.chapter3.patternNodeId`), not her Chapter-1 Capability. This matters mechanically,
not just narratively: `Install.install/3`'s Crosswalk auto-mapping (the whole payoff of this
Chapter) only applies to Rules — Capability copy-on-install (6q §4.7) is a separate, simpler,
no-Crosswalk mechanism. Using the Chapter-1 Capability here would need the other install endpoint
and wouldn't show any field-mapping at all.

1. Guild B bootstrap: identical flow to Chapter 0, `"name": "guild-b"`, `"username": "bob"`.
   Stores `state.guildB.*`.
2. Guild B admits her own differently-named-predicate Rule into her own Catalog first (an ordinary
   `POST /tenants/{guildB.tenantId}/propose` + approve) — e.g. `guildBAwardedBadge(...)`, stored as
   `state.chapter4.guildBLocalRuleNodeId`. This establishes the "pre-existing local convention" the
   Crosswalk step needs to be meaningful, per the original narrative's own explicit framing.
3. A second pane opens showing Guild A's own catalog, live: `subscribeStream` against
   `{baseUrl}/tenants/{guildA.tenantId}/resources/catalog`'s stream (the same
   `ResourceController.stream_id_for/2` shape every other Tenant resource read already uses), with
   incoming patch quads rendered as a running "Guild A's public noticeboard" list.
4. Guild A grants `:public` read: `POST /tenants/{guildA.tenantId}/policies`,
   `{"effect": "allow", "modes": ["read"], "matcher": "public"}`. The live pane (already
   subscribed) shows this doesn't itself write a new Catalog entry — it's Guild A's already-admitted
   Chapter-3 pattern becoming visible to Guild B for the first time, so the pane's own narration
   makes clear the *policy grant*, not a new fact, is what just happened.
5. Guild B resolves the name: `GET /tenant-names/guild-a` → `{"tenant_id": "..."}`, then
   `GET /tenants/{guildA.tenantId}/discovery/search?q=<the Chapter-3 pattern's own predicate name>`
   — succeeds with Guild B's own token subject to the public-read rate limit (6q §4.6),
   demonstrating the discovery surface without needing Alice's own credentials. The response is
   Turtle; parsed via `fetchTurtle` (§4.6) to find the matching Rule's own blank-node subject, whose
   `.value` becomes `state.chapter4.discoveredNodeId`.
6. Guild B installs the discovered pattern: `POST /tenants/{guildB.tenantId}/install`,
   `{"source_tenant_id": guildA.tenantId, "node_id": chapter4.discoveredNodeId}`, storing the
   review's own `node_id` as `state.chapter4.installReviewNodeId`, then approves it. The install
   response/Crosswalk auto-mapping renders which fields matched Guild B's own vocabulary
   automatically vs. which need her manual confirmation (Provenance's own `field_bindings`, already
   present in `Install.install/3`'s output).
7. Guild A proposes a v2 of her Chapter-3 pattern with `"replaces": chapter3.patternNodeId`
   (stored as `state.chapter4.v2PatternNodeId`), approves — the live pane (still subscribed) shows
   the v1 entry's own status flip to superseded while staying visible (full history, not deleted).

### 4.9 Chapters 5 and 6 — Mutex + recursive query

**Chapter 5 ("no double-loot")**: two "Submit" buttons, each independently wired to fire
`POST /tenants/{guildA.tenantId}/tasks` with identical `"mutex_key": "guild-demo-shared-chest"` and
distinct descriptions, both targeting a Capability with a deliberate multi-second processing delay
(reusing Chapter 1's own taught Capability is sufficient — no new Capability needed, since the
mutex behavior is about `JobTrigger`'s own exclusion logic, orthogonal to which Capability runs).
Both fired via `Promise.all` so they're genuinely concurrent from the client's perspective. Both
Jobs watched live via `subscribeStream`; each renders as a growing horizontal bar on a shared
timeline (bar start = Job's own `jobStatus` transition to a running-equivalent state — since
`Job` has no explicit "running" status distinct from "pending"/"done"/"failed" today, the bar
starts at Task-submission time client-side and ends when the Job's stream reports `"done"`/
`"failed"`, which is sufficient to show the non-overlap even though it slightly over-counts queue
wait as "processing" — noted as a known simplification, not hidden). Payoff is purely visual: the
two bars render sequentially, never overlapping.

**Chapter 6 ("ask a question")**: a small pre-filled recursive ruleset (two Rules sharing one head
predicate — a base clause and a recursive clause, the same shape 6c-ii's own worked examples use)
gets admitted via the ordinary propose+approve flow. A small form (two text fields: skill name,
target character) writes a starting fact via
`PUT /tenants/{guildA.tenantId}/resources/characters/alice` (visitor-editable, pre-filled with one
starting skill). "Ask the question" button:
`POST /tenants/{guildA.tenantId}/query {"starting_resource_path": ["characters", "alice"]}`,
response parsed via `fetchTurtle`'s same N3-backed approach, rendered as two lists side by side:
"Alice's own facts" (everything present before the query) vs. "Everything Alice's guild now knows
she can do" (the full result graph minus the starting facts — i.e. what fixpoint evaluation newly
derived). This is the demo's closing Chapter; no "Next chapter" button, a closing summary panel
instead.

## 5. Worked example

A single continuous run, opening the page fresh:

1. Chapter 0: visitor accepts the default `http://localhost:4000`, clicks Begin — Alice/Guild A
   exist.
2. Chapter 1: visitor selects `badge-qr-generator.wasm`, teaches it, edits the badge text to "You
   got this!", submits — watches the Job complete, sees the rendered SVG badge.
3. Chapter 2: visitor selects `curse.wasm`, teaches it, submits the pre-filled description — watches
   the Job fail, sees the clean trap message.
4. Chapter 3: visitor submits a second badge-flavored Task (LLM resolves it again), proposes the
   pattern from both Jobs, reviews the generalization/fidelity evidence, approves, submits a third —
   sees it resolve via Discovery instantly.
5. Chapter 4: Guild B bootstraps, admits her own differently-named Rule, watches Guild A's live
   pane, grants public read on Guild A's side, resolves the name, discovers, installs with
   Crosswalk auto-mapping, watches Guild A ship a v2 and the pane show v1 superseded.
6. Chapter 5: visitor fires both "Submit" buttons together, watches two non-overlapping bars
   render.
7. Chapter 6: visitor asks the pre-filled skill-tree question, sees the derived-skills closure
   render.

## 6. Error handling

Every write in this page already has documented status codes from the specs that shipped its own
endpoint (6p-i §6, 6k/6n/6q's own controllers) — this page's own job is rendering them clearly, not
inventing new ones. A shared `renderError(httpError)` helper maps the common cases visitors could
actually hit:

- `409` on Chapter 0's signup (name already claimed — a non-fresh instance): "guild-a is already
  claimed on this Riptide instance — point the demo at a fresh one." No retry affordance; this
  isn't recoverable without a different instance.
- `422 llm_fallback_failed` on any Chapter 1-3 Task submission: "The backend's LLM API call failed
  — confirm `LLM_API_BASE_URL`/`LLM_API_KEY`/`LLM_API_MODEL` are set on the Riptide instance (see
  README)." This is the single most likely real-world failure mode (§4.1), so gets its own
  specific, actionable message rather than a generic error panel.
- `429` on any write (rate-limited): "Rate-limited — wait a moment and try again," with the action
  button re-enabled immediately (no auto-retry, so a visitor doesn't accidentally hammer the
  limit further).
- `503` on any call (placement cluster transiently unreachable): "Backend temporarily unavailable —
  try again," button re-enabled.
- Any other non-2xx: a generic panel showing the raw status + body, since this is a demo a
  developer is actively watching, not an end-user product — raw detail is more useful than a
  polished generic message once the specific cases above are exhausted.
- `EventSource` connection errors (network drop mid-Chapter 1-6): the affected Chapter shows a
  "Reconnecting…" indicator; `subscribeStream`'s caller re-invokes it after a short delay rather
  than the page silently hanging with no feedback.

## 7. Testing

`examples/guild-demo/smoke-test.mjs` — a standalone Node script using the `playwright` package
(already available on any box with this repo, per this box's own convention of plain scripts over
MCP servers). Launches a real browser, opens `index.html` via `file://`, and drives all seven
Chapters in sequence against a Riptide instance the script itself boots
(`mix phx.server`, requires `LLM_API_BASE_URL`/`LLM_API_KEY`/`LLM_API_MODEL` set in the invoking
shell — the script fails fast with a clear message if they're absent, rather than limping through
Chapters 0 and then failing confusingly at Chapter 1). Asserts, per Chapter, that the payoff
described in §4.4-4.9 actually renders (the SVG badge appears, the trap message appears, the
fidelity evidence appears, the live pane updates, the two timeline bars don't overlap, the derived
skill list is non-empty). Not part of `mix test` or CI — run manually, on demand, documented in
`examples/guild-demo/README.md`.

## 8. Explicitly out of scope

See §3 (Non-goals): a build step/bundler, a backend LLM stub, cross-reload persistence, anything
6q itself scoped out, and an automated CI-integrated test suite for the page.
