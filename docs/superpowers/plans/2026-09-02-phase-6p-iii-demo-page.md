# Phase 6p-iii — The Sub-project 6 Demo Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `examples/guild-demo/index.html` — a single-file, RPG-tutorial-styled walkthrough that drives all seven Chapters (0-6) of the Sub-project 6 demo narrative against a live Riptide instance, plus the tooling to verify it (a Playwright smoke test and the mock LLM server that makes it runnable without a real vendor API key).

**Architecture:** One HTML file (structure, CSS, vanilla JS, no build step) opened directly via `file://`. A flat `state` object threads real IDs (tenant ids, tokens, job/node ids) between Chapters. Every Chapter performs real HTTP calls against the already-shipped backend (6p-i, 6k/6n, 6q) and renders the real response — no new backend code anywhere in this plan. A standalone Node+Playwright script drives the page end-to-end for verification, backed by a tiny mock LLM server (testing-only infrastructure, not shipped as part of the demo itself) so Chapters 1-3 are verifiable without a real API key or non-deterministic LLM output.

**Tech Stack:** Vanilla JS/CSS/HTML, N3.js (via CDN) for Turtle parsing, Node.js + Playwright (already available on this box) + Node's built-in `http` module for the mock LLM server — zero new dependencies added to `mix.exs`.

**Spec:** `docs/superpowers/specs/2026-09-02-phase-6p-iii-demo-page-design.md`

## Global Constraints

- No build step, bundler, or npm dependency for `index.html` itself — the only external load is N3.js via `<script src="https://unpkg.com/n3/browser/n3.min.js">`.
- No backend code changes anywhere in this plan — every endpoint already exists (confirmed exact request/response shapes against the real controllers during planning, cited per-task below).
- "Beat" is never used anywhere in this plan's own UI copy or code comments — the seven sections are **Chapters** (Chapter 0 bootstrap, Chapters 1-6 narrative), per the spec's own terminology decision.
- The demo's own product-facing docs/copy never name a specific LLM vendor (per 6r) — only `LLM_API_BASE_URL`/`LLM_API_KEY`/`LLM_API_MODEL` are referenced.
- The mock LLM server (`examples/guild-demo/mock-llm-server.mjs`) and the Playwright smoke test are testing/verification infrastructure only — not part of what a real visitor opens; this is consistent with, not a violation of, the spec's own "no backend LLM stub mode" non-goal (that referred to the *shipped* backend, not this phase's own test tooling).

---

## Task 1: Mock LLM server (testing infrastructure)

**Files:**
- Create: `examples/guild-demo/mock-llm-server.mjs`

**Interfaces:**
- Produces: a standalone Node HTTP server (no dependencies — Node's built-in `http` module only) implementing the OpenAI-compatible `POST /chat/completions` endpoint `Riptide.Derivation.LLMFallback.Client.OpenAICompatible` (6r) actually calls: request body `{model, messages: [{role, content}]}`, response body `{choices: [{message: {content}}]}`.
- Consumes: nothing — this is a leaf script, runnable standalone via `node mock-llm-server.mjs [port]` (default port `4100`).

This task has no dependency on the demo page itself and is verified directly via `curl`, so it comes first.

- [ ] **Step 1: Write the server**

Create `examples/guild-demo/mock-llm-server.mjs`:

```js
#!/usr/bin/env node
// Minimal OpenAI-compatible chat-completions mock, for verifying the guild demo end-to-end
// without a real LLM vendor API key or non-deterministic output. NOT part of the shipped demo —
// testing infrastructure only, started by smoke-test.mjs (or standalone for manual poking).
import { createServer } from "node:http";

// Keyed by an exact substring of the incoming prompt's own "Task: <description>" line — the
// smoke test always submits these exact, known descriptions (a real visitor might type anything,
// which is fine: an unmatched prompt gets a 500, surfaced to the demo's own error handling, never
// silently wrong).
//
// IMPORTANT: the two badge-flavored completions share the exact same head predicate
// (badgeResult) and first head argument — Riptide.Derivation.AntiUnifier.check_heads_compatible/2
// requires an EXACT predicate match between two traces before they can be generalized at all
// (confirmed by reading anti_unifier.ex directly during planning), so Chapter 3's own "propose
// this as a pattern" step would fail with {:error, :no_common_structure} if these diverged.
const CANNED_COMPLETIONS = [
  {
    match: "make a badge that says Welcome, Adventurer!",
    rule:
      'badgeResult(<urn:riptide:demo:badge>, Result) :- capability(guildDemoBadge, "Welcome, Adventurer!", Result).',
  },
  {
    match: "make a badge that says Great job, Champion!",
    rule:
      'badgeResult(<urn:riptide:demo:badge>, Result) :- capability(guildDemoBadge, "Great job, Champion!", Result).',
  },
  {
    match: "try the cursed amulet",
    rule:
      'curseResult(<urn:riptide:demo:curse>, Result) :- capability(guildDemoCurse, Result).',
  },
  // Chapter 4's "ship a v2" step (Task 6): needs a Job with a real, freshly-resolved trace to
  // generalize a superseding pattern from — reusing either of the two Jobs already generalized
  // into v1 just reproduces the identical Rule, which DedupGate correctly rejects as redundant
  // (confirmed live). Worded with no "badge"/"result" word at all so Discovery.find/2's own
  // tokenized word-overlap match (against v1's already-admitted badgeResult predicate) never
  // intercepts this Task before it reaches LLM fallback — same head predicate as the other two
  // badge completions, per the exact-head-match constraint noted above.
  {
    match: "forge a token for the newest arrival",
    rule:
      'badgeResult(<urn:riptide:demo:badge>, Result) :- capability(guildDemoBadge, "You\'re the newest arrival!", Result).',
  },
];

function findCompletion(prompt) {
  const hit = CANNED_COMPLETIONS.find((c) => prompt.includes(c.match));
  return hit ? hit.rule : null;
}

export function startMockLlmServer(port) {
  const server = createServer((req, res) => {
    if (req.method !== "POST" || req.url !== "/chat/completions") {
      res.writeHead(404).end();
      return;
    }

    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const { messages } = JSON.parse(body);
      const prompt = messages[messages.length - 1].content;
      const rule = findCompletion(prompt);

      if (!rule) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: `mock-llm-server: no canned completion matches prompt: ${prompt}` }));
        return;
      }

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ choices: [{ message: { content: rule } }] }));
    });
  });

  return new Promise((resolve) => {
    server.listen(port, () => resolve(server));
  });
}

// Runnable standalone: `node mock-llm-server.mjs [port]`
if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.argv[2] ?? 4100);
  await startMockLlmServer(port);
  console.log(`mock-llm-server listening on :${port}`);
}
```

- [ ] **Step 2: Verify it standalone**

Run: `node examples/guild-demo/mock-llm-server.mjs 4100 &` then, in the same shell:

```bash
curl -s -X POST http://localhost:4100/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"x","messages":[{"role":"user","content":"...\nTask: make a badge that says Welcome, Adventurer!\n\nOutput ONLY..."}]}'
```

Expected: `{"choices":[{"message":{"content":"badgeResult(<urn:riptide:demo:badge>, Result) :- capability(guildDemoBadge, \"Welcome, Adventurer!\", Result)."}}]}`. Also confirm an unmatched prompt returns `500` with a clear error body. Kill the background server (`kill %1`) once confirmed.

- [ ] **Step 3: Commit**

```bash
git add examples/guild-demo/mock-llm-server.mjs
git commit -m "Add mock LLM server for guild-demo verification (6p-iii)"
```

---

## Task 2: Page shell, state model, and data-access helpers

**Files:**
- Create: `examples/guild-demo/index.html`

**Interfaces:**
- Produces: the page shell (quest-log sidebar + main panel), the `state` object, `fetchTurtle`/`subscribeStream`/`postJson`/`renderError` helpers, a `CHAPTERS` array + stepper engine that later tasks append Chapter definitions into.
- Consumes: N3.js (global `N3`), loaded via CDN script tag.

No Chapters are implemented yet — this task is verified by opening the file directly in a browser and confirming the shell renders (sidebar lists placeholder Chapter titles, no console errors) — there's nothing to click through yet, so no Playwright assertion for this task specifically (Task 3 adds the first one, for Chapter 0).

- [ ] **Step 1: Write the page shell**

Create `examples/guild-demo/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>A Guild's First Day — the Riptide Demo</title>
<script src="https://unpkg.com/n3/browser/n3.min.js"></script>
<style>
  :root {
    --parchment: #f4e8d0;
    --ink: #2b2116;
    --gold: #b8860b;
    --danger: #8b2e2e;
    --success: #2e6b3e;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; display: flex; min-height: 100vh;
    font-family: Georgia, 'Times New Roman', serif;
    background: var(--parchment); color: var(--ink);
  }
  #quest-log {
    width: 240px; padding: 1.5rem 1rem; background: #e8d8b0;
    border-right: 2px solid var(--gold); flex-shrink: 0;
  }
  #quest-log h1 { font-size: 1.1rem; margin: 0 0 1rem; }
  #quest-log ol { list-style: none; margin: 0; padding: 0; }
  #quest-log li { padding: 0.4rem 0; opacity: 0.5; }
  #quest-log li.current { opacity: 1; font-weight: bold; color: var(--gold); }
  #quest-log li.done { opacity: 0.8; }
  #quest-log li.done::before { content: "✓ "; color: var(--success); }
  #chapter-view { flex: 1; padding: 2rem; max-width: 720px; }
  button {
    font-family: inherit; background: var(--gold); color: white; border: none;
    padding: 0.5rem 1rem; border-radius: 4px; cursor: pointer; font-size: 1rem;
  }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  input[type="text"], input[type="url"], input[type="file"] {
    font-family: inherit; padding: 0.4rem; width: 100%; margin: 0.4rem 0;
  }
  .payoff { background: white; border: 1px solid #ccc; border-radius: 4px; padding: 1rem; margin-top: 1rem; }
  .error { background: #fdecea; border: 1px solid var(--danger); color: var(--danger); padding: 0.75rem; border-radius: 4px; margin-top: 0.75rem; }
</style>
</head>
<body>
  <nav id="quest-log">
    <h1>A Guild's First Day</h1>
    <ol id="quest-log-list"></ol>
  </nav>
  <main id="chapter-view"></main>

<script>
// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
const state = {
  baseUrl: null,
  guildA: { tenantId: null, aliceToken: null, aliceSub: null },
  guildB: { tenantId: null, bobToken: null, bobSub: null },
  chapter1: { capabilityNodeId: null, jobNodeId: null },
  chapter2: { capabilityNodeId: null, jobNodeId: null },
  chapter3: { secondJobNodeId: null, patternNodeId: null, thirdJobNodeId: null },
  chapter4: { guildBLocalRuleNodeId: null, discoveredNodeId: null, installReviewNodeId: null, v2PatternNodeId: null },
  chapter5: { job1NodeId: null, job2NodeId: null },
  chapter6: { ruleNodeId: null },
};

// ---------------------------------------------------------------------------
// Data-access helpers
// ---------------------------------------------------------------------------
class HttpError extends Error {
  constructor(status, body) {
    super(`HTTP ${status}`);
    this.status = status;
    this.body = body;
  }
}

async function fetchTurtle(path, token) {
  const res = await fetch(state.baseUrl + path, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  const text = await res.text();
  if (!res.ok) throw new HttpError(res.status, text);
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
  return text === "" ? null : JSON.parse(text);
}

async function putTurtle(path, token, turtle) {
  const res = await fetch(state.baseUrl + path, {
    method: "PUT",
    headers: { "Content-Type": "text/turtle", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: turtle,
  });
  const text = await res.text();
  if (!res.ok) throw new HttpError(res.status, text);
}

async function sha256hex(text) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Riptide's own RDF vocabulary IRIs — mirrors the exact terms the backend's own RDF codecs write
// (JobRDFCodec, CapabilityCatalogRDFCodec, etc.), confirmed directly against
// lib/riptide/derivation/job_rdf_codec.ex during planning.
const VOCAB = {
  jobStatus: "urn:riptide:vocab:jobStatus",
  jobResult: "urn:riptide:vocab:jobResult",
  jobError: "urn:riptide:vocab:jobError",
};

function renderError(err, container) {
  const div = document.createElement("div");
  div.className = "error";
  if (err instanceof HttpError) {
    div.textContent = errorMessageFor(err);
  } else {
    div.textContent = `Unexpected error: ${err.message}`;
  }
  container.appendChild(div);
}

function errorMessageFor(err) {
  if (err.status === 409) return "This name is already claimed on this Riptide instance — point the demo at a fresh one.";
  if (err.status === 422 && err.body.includes("llm_fallback_failed")) {
    return "The backend's LLM API call failed — confirm LLM_API_BASE_URL/LLM_API_KEY/LLM_API_MODEL are set on the Riptide instance (see README).";
  }
  if (err.status === 429) return "Rate-limited — wait a moment and try again.";
  if (err.status === 503) return "Backend temporarily unavailable — try again.";
  return `HTTP ${err.status}: ${err.body}`;
}

// ---------------------------------------------------------------------------
// Stepper engine — Chapter definitions are pushed onto this array by later tasks, each as
// { title, render(container) } where render() populates #chapter-view for that Chapter and is
// responsible for calling advanceToNext() once its own payoff has rendered.
// ---------------------------------------------------------------------------
const CHAPTERS = [];
let currentChapterIndex = 0;

function renderQuestLog() {
  const list = document.getElementById("quest-log-list");
  list.innerHTML = "";
  CHAPTERS.forEach((chapter, i) => {
    const li = document.createElement("li");
    li.textContent = chapter.title;
    if (i < currentChapterIndex) li.className = "done";
    if (i === currentChapterIndex) li.className = "current";
    list.appendChild(li);
  });
}

function renderCurrentChapter() {
  renderQuestLog();
  const container = document.getElementById("chapter-view");
  container.innerHTML = "";
  CHAPTERS[currentChapterIndex].render(container);
}

function advanceToNext() {
  currentChapterIndex += 1;
  if (currentChapterIndex < CHAPTERS.length) renderCurrentChapter();
}

function addNextButton(container, label = "Next chapter →") {
  const btn = document.createElement("button");
  btn.textContent = label;
  btn.onclick = advanceToNext;
  container.appendChild(btn);
}

window.addEventListener("DOMContentLoaded", renderCurrentChapter);
</script>
</body>
</html>
```

- [ ] **Step 2: Verify the shell**

Open `examples/guild-demo/index.html` directly in a browser (`file://` path). Expected: the parchment-themed shell renders, the quest log is empty (no Chapters registered yet — `CHAPTERS` is `[]`), no console errors. This confirms the N3.js CDN load succeeds and the base structure is sound before any Chapter logic depends on it.

- [ ] **Step 3: Commit**

```bash
git add examples/guild-demo/index.html
git commit -m "Add guild-demo page shell, state model, and data-access helpers (6p-iii)"
```

---

## Task 3: Smoke-test harness + Chapter 0 (bootstrap)

**Files:**
- Create: `examples/guild-demo/smoke-test.mjs`
- Modify: `examples/guild-demo/index.html` (add Chapter 0)

**Interfaces:**
- Consumes: `startMockLlmServer` (Task 1), the page shell/stepper (Task 2).
- Produces: the smoke-test harness (boots `mix phx.server` + the mock LLM server, opens the page via Playwright, tears both down after) that every later task's own Chapter extends with one more assertion. `POST /auth/signup` confirmed against `lib/riptide_web/auth/signup_controller.ex` during planning: `{"name", "username", "password_hash"}` in, `{"token", "sub", "tenant_id"}` out on `200`, `409` on an already-claimed name.

- [ ] **Step 1: Write the failing smoke test**

Create `examples/guild-demo/smoke-test.mjs`:

```js
#!/usr/bin/env node
// Standalone verification for the guild-demo page — NOT part of `mix test`/CI (needs a running
// dev server; the mock LLM server it also boots removes the *real-API-key* dependency, but a live
// Riptide instance is still required). Run manually: `node examples/guild-demo/smoke-test.mjs`.
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { startMockLlmServer } from "./mock-llm-server.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RIPTIDE_ROOT = path.resolve(__dirname, "../..");
const BASE_URL = "http://localhost:4000";
const MOCK_LLM_PORT = 4100;

function log(msg) {
  console.log(`[smoke-test] ${msg}`);
}

async function waitForReady(url, attempts = 60) {
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`${url} never became ready`);
}

async function main() {
  const mockLlm = await startMockLlmServer(MOCK_LLM_PORT);
  log(`mock LLM server up on :${MOCK_LLM_PORT}`);

  const server = spawn("mix", ["phx.server"], {
    cwd: RIPTIDE_ROOT,
    env: {
      ...process.env,
      LLM_API_BASE_URL: `http://localhost:${MOCK_LLM_PORT}`,
      LLM_API_KEY: "smoke-test-key",
      LLM_API_MODEL: "smoke-test-model",
    },
    stdio: "inherit",
  });

  try {
    await waitForReady(`${BASE_URL}/health/ready`);
    log("Riptide dev server ready");

    const browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(`file://${path.join(__dirname, "index.html")}`);

    await runChapters(page);

    await browser.close();
    log("ALL CHAPTERS PASSED");
  } finally {
    server.kill();
    mockLlm.close();
  }
}

async function runChapters(page) {
  // Chapter 0
  await page.fill('#base-url-input', BASE_URL);
  await page.click('#begin-button');
  await page.waitForSelector('.payoff:has-text("Welcome, Alice")', { timeout: 10000 });
  log("Chapter 0 passed");
  await page.click('button:has-text("Next chapter")');

  // Later tasks append one more `log(...)` + assertion block here per Chapter, in order.
}

main().catch((err) => {
  console.error("[smoke-test] FAILED:", err);
  process.exitCode = 1;
});
```

- [ ] **Step 2: Run it to confirm it fails**

Requires `LLM_API_BASE_URL`/`LLM_API_KEY`/`LLM_API_MODEL` are *not* required to be pre-set (the script sets them itself for the child `mix phx.server` process). Run: `node examples/guild-demo/smoke-test.mjs`
Expected: FAIL — `page.waitForSelector('.payoff:has-text("Welcome, Alice")')` times out, since Chapter 0 doesn't exist in `index.html` yet (`CHAPTERS` is still empty, `#base-url-input`/`#begin-button` don't exist).

- [ ] **Step 3: Implement Chapter 0**

Add to `index.html`'s `<script>` block, after the stepper engine (before `window.addEventListener`):

```js
CHAPTERS.push({
  title: "Chapter 0: Bootstrap",
  render(container) {
    container.innerHTML = `
      <h2>Chapter 0: Bootstrap</h2>
      <p>Every run of this demo mints a brand-new guild. Point it at your Riptide instance:</p>
      <label>API base URL: <input type="url" id="base-url-input" value="http://localhost:4000" /></label>
      <button id="begin-button">Begin</button>
      <div id="chapter0-result"></div>
    `;
    document.getElementById("begin-button").onclick = () => beginChapter0(container);
  },
});

async function beginChapter0(container) {
  const result = document.getElementById("chapter0-result");
  result.innerHTML = "";
  state.baseUrl = document.getElementById("base-url-input").value;

  try {
    const passwordHash = await sha256hex("guild-demo-pw");
    const response = await postJson("/auth/signup", null, {
      name: "guild-a",
      username: "alice",
      password_hash: passwordHash,
    });
    state.guildA.tenantId = response.tenant_id;
    state.guildA.aliceToken = response.token;
    state.guildA.aliceSub = response.sub;

    const payoff = document.createElement("div");
    payoff.className = "payoff";
    payoff.textContent = "Welcome, Alice of Guild A!";
    result.appendChild(payoff);
    addNextButton(result);
  } catch (err) {
    renderError(err, result);
  }
}
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: PASS — logs `[smoke-test] Chapter 0 passed`, then `[smoke-test] ALL CHAPTERS PASSED`. If it 409s (a prior run's `guild-a` name is still claimed on this dev instance), stop the dev server, clear its data directories (`rm -rf priv/ra_data_dev` or equivalent, matching this repo's own `priv/ra_data_test` convention), and rerun.

- [ ] **Step 5: Commit**

```bash
git add examples/guild-demo/index.html examples/guild-demo/smoke-test.mjs
git commit -m "Add smoke-test harness and Chapter 0 bootstrap (6p-iii)"
```

---

## Task 4: Chapters 1 and 2 — Teach + use a Capability

**Files:**
- Modify: `examples/guild-demo/index.html` (add Chapters 1, 2)
- Modify: `examples/guild-demo/smoke-test.mjs` (extend `runChapters`)

**Interfaces:**
- Consumes: `state.guildA` (Task 3), the mock LLM server's two badge-flavored responses (Task 1) plus its curse response, `VOCAB`/`fetchTurtle`/`subscribeStream`/`postJson` (Task 2).
- Produces: `state.chapter1.{capabilityNodeId,jobNodeId}`, `state.chapter2.{capabilityNodeId,jobNodeId}`.
- Confirmed exact shapes during planning: `POST /tenants/:id/capabilities` body `{name, kind, function, fuel_limit, timeout_ms, memory_limits, component_bytes}` → `{node_id}` (`lib/riptide_web/tenant_capability_controller.ex`); `POST .../capability-reviews/:id/approve` → `200`, empty body; `POST /tenants/:id/tasks` body `{description}` → `{job_node, resolved_via}` (`lib/riptide_web/task_controller.ex`); Job's own RDF predicates `jobStatus`/`jobResult`/`jobError` (confirmed against `job_rdf_codec.ex`).

- [ ] **Step 1: Write the failing test**

Extend `runChapters` in `smoke-test.mjs`, after the Chapter 0 block:

```js
  // Chapter 1
  await page.setInputFiles('#chapter1-wasm-input', path.join(__dirname, "capabilities/badge-qr-generator/badge-qr-generator.wasm"));
  await page.click('#chapter1-teach-button');
  await page.waitForSelector('#chapter1-use-section', { timeout: 10000 });
  await page.click('#chapter1-submit-button'); // uses the pre-filled default description
  await page.waitForSelector('.payoff svg', { timeout: 15000 });
  log("Chapter 1 passed");
  await page.click('button:has-text("Next chapter")');

  // Chapter 2
  await page.setInputFiles('#chapter2-wasm-input', path.join(__dirname, "capabilities/curse/curse.wasm"));
  await page.click('#chapter2-teach-button');
  await page.waitForSelector('#chapter2-use-section', { timeout: 10000 });
  await page.click('#chapter2-submit-button');
  await page.waitForSelector('.payoff:has-text("backfires")', { timeout: 15000 });
  log("Chapter 2 passed");
  await page.click('button:has-text("Next chapter")');
```

- [ ] **Step 2: Run to verify it fails**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: FAIL at `page.setInputFiles('#chapter1-wasm-input', ...)` — Chapter 1 doesn't exist yet.

- [ ] **Step 3: Implement Chapters 1 and 2**

Add to `index.html`'s `<script>` block, after Chapter 0's own code:

```js
function pushCapabilityChapter({ title, stateKey, wasmPath, capabilityName, capabilityFunction, defaultDescription, onDone }) {
  CHAPTERS.push({
    title,
    render(container) {
      container.innerHTML = `
        <h2>${title}</h2>
        <p>Teach Guild A this capability:</p>
        <input type="file" id="${stateKey}-wasm-input" accept=".wasm" />
        <p style="font-size:0.9em">Select <code>${wasmPath}</code> (relative to this page).</p>
        <button id="${stateKey}-teach-button">Teach this capability</button>
        <div id="${stateKey}-teach-result"></div>
      `;
      document.getElementById(`${stateKey}-teach-button`).onclick = () =>
        teachCapability(container, stateKey, capabilityName, capabilityFunction);
    },
  });

  return { onDone };
}

async function teachCapability(container, stateKey, capabilityName, capabilityFunction) {
  const teachResult = document.getElementById(`${stateKey}-teach-result`);
  teachResult.innerHTML = "";
  const fileInput = document.getElementById(`${stateKey}-wasm-input`);

  try {
    const bytes = await fileInput.files[0].arrayBuffer();
    const b64 = btoa(String.fromCharCode(...new Uint8Array(bytes)));

    const propose = await postJson(`/tenants/${state.guildA.tenantId}/capabilities`, state.guildA.aliceToken, {
      name: capabilityName,
      kind: "effect",
      function: capabilityFunction,
      fuel_limit: 100000000,
      timeout_ms: 5000,
      memory_limits: { max_memory_size: null, max_table_elements: null, max_instances: null, max_tables: null },
      component_bytes: b64,
    });
    state[stateKey].capabilityNodeId = propose.node_id;

    await postJson(`/tenants/${state.guildA.tenantId}/capability-reviews/${propose.node_id}/approve`, state.guildA.aliceToken, {});

    // A Job's actual execution runs asynchronously on whichever node leads its stream, with no
    // per-request subject at all (Riptide.Derivation.JobTrigger.execute/3 always invokes with a
    // nil current_subject) — so :invoke authorization can only ever be satisfied by a
    // subject-agnostic (:public) policy, never an owner-scoped {:agent, sub} one. This is the
    // same explicit "admit into your Catalog, then separately grant a :public policy" two-step
    // RiptideWeb.TenantCapabilityController's own moduledoc describes, and the same pattern every
    // real end-to-end capstone test in this codebase already seeds.
    await postJson(`/tenants/${state.guildA.tenantId}/policies`, state.guildA.aliceToken, {
      effect: "allow",
      modes: ["invoke"],
      matcher: "public",
    });

    const badge = document.createElement("div");
    badge.className = "payoff";
    badge.textContent = "✓ Taught";
    teachResult.appendChild(badge);
    renderUseSection(container, stateKey);
  } catch (err) {
    renderError(err, teachResult);
  }
}

function renderUseSection(container, stateKey) {
  const section = document.createElement("div");
  section.id = `${stateKey}-use-section`;
  const defaultDescription = stateKey === "chapter1" ? "make a badge that says Welcome, Adventurer!" : "try the cursed amulet";
  section.innerHTML = `
    <p>Now put it to use:</p>
    <input type="text" id="${stateKey}-description-input" value="${defaultDescription}" />
    <button id="${stateKey}-submit-button">Submit Task</button>
    <div id="${stateKey}-use-result"></div>
  `;
  container.appendChild(section);
  document.getElementById(`${stateKey}-submit-button`).onclick = () => useCapability(container, stateKey);
}

async function useCapability(container, stateKey) {
  const useResult = document.getElementById(`${stateKey}-use-result`);
  useResult.innerHTML = "";
  const description = document.getElementById(`${stateKey}-description-input`).value;

  try {
    const submitted = await postJson(`/tenants/${state.guildA.tenantId}/tasks`, state.guildA.aliceToken, { description });
    state[stateKey].jobNodeId = submitted.job_node;

    const streamId = `https://riptide.example/tenants/${state.guildA.tenantId}/resources/jobs`;
    const es = subscribeStream(streamId, state.guildA.aliceToken, (quads) => {
      // Not matched against submitted.job_node: a Job's blank-node subject has no identity
      // outside the one Turtle document it was originally written in — each SSE frame is parsed
      // independently by N3.js, and Riptide.RDF.TurtleCodec (a thin wrapper over the `rdf`
      // library's own standard, spec-legal Turtle writer) renders a blank node with zero inbound
      // references using anonymous `[...]` syntax, which carries no label at all. Confirmed live:
      // a fresh subscribe's very first frame shows the Job as `[ a <urn:riptide:vocab:Job> ; ...
      // ]`, and Catalog.mark_job_done/3's own completion patch (lib/riptide/derivation/catalog.ex)
      // writes only jobStatus/jobResult, so there's no other field in that same frame to
      // correlate by either. Each Chapter here only ever has one Job in flight at a time, so
      // matching on "a jobStatus quad just turned done/failed" — with no subject check at all —
      // is unambiguous and correct for this demo's own narrative.
      const statusQuad = quads.find((q) => q.predicate.value === VOCAB.jobStatus);
      if (!statusQuad) return;
      const status = statusQuad.object.value;
      if (status !== "done" && status !== "failed") return;
      es.close();
      renderCapabilityPayoff(useResult, stateKey, status, quads);
    });
  } catch (err) {
    // The curse capability traps on EVERY invocation — LLMFallback.run/3 actually invokes the
    // Capability for real to ground a binding before it ever writes a Job (see
    // resolve_exactly_one_binding/3 in lib/riptide/derivation/llm_fallback.ex), so a
    // never-succeeds capability fails right here, synchronously, as a 422 on the Task submission
    // itself — no Job is ever written, so there's no async "failed" status to watch for over SSE
    // the way Chapter 1's own success path works. Route straight to the same payoff a "failed"
    // Job would have gotten; any other error (wrong description, network, etc.) still surfaces
    // through the normal error path.
    if (stateKey === "chapter2" && err instanceof HttpError && err.status === 422) {
      renderCapabilityPayoff(useResult, stateKey, "failed", []);
    } else {
      renderError(err, useResult);
    }
  }
}

function renderCapabilityPayoff(container, stateKey, status, quads) {
  const payoff = document.createElement("div");
  payoff.className = "payoff";

  if (stateKey === "chapter1" && status === "done") {
    const resultQuad = quads.find((q) => q.predicate.value === VOCAB.jobResult);
    // Capability.invoke/4 returns a JSON-encoded string (e.g. "\"<svg>...</svg>\"") — the Job's
    // own jobResult literal carries it verbatim; JSON.parse unwraps the outer encoding.
    payoff.innerHTML = JSON.parse(resultQuad.object.value);
  } else if (stateKey === "chapter2" && status === "failed") {
    // No errorQuad at all in the (actual, common) synchronous-422 case above — quads is [].
    const errorQuad = quads.find((q) => q.predicate.value === VOCAB.jobError);
    const errorText = errorQuad ? errorQuad.object.value : "the capability trapped before a Job could even be written";
    payoff.innerHTML = `<strong>The curse backfires!</strong><p>${errorText}</p><p><em>WASI caught the fault cleanly — no crash, no hang, just a clean trap.</em></p>`;
  } else {
    payoff.textContent = `Unexpected Job status: ${status}`;
  }

  container.appendChild(payoff);
  addNextButton(container);
}

pushCapabilityChapter({
  title: "Chapter 1: Teach Riptide its first trick",
  stateKey: "chapter1",
  wasmPath: "capabilities/badge-qr-generator/badge-qr-generator.wasm",
  capabilityName: "urn:riptide:capability:guildDemoBadge",
  capabilityFunction: "generate-qr-code",
});

pushCapabilityChapter({
  title: "Chapter 2: A capability that bites back",
  stateKey: "chapter2",
  wasmPath: "capabilities/curse/curse.wasm",
  capabilityName: "urn:riptide:capability:guildDemoCurse",
  capabilityFunction: "curse",
});
```

- [ ] **Step 4: Run to verify it passes**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: PASS through `[smoke-test] Chapter 2 passed`. If Chapter 1 hangs waiting for `.payoff svg`, confirm `mock-llm-server.mjs`'s Chapter-1 canned response's `match` string is byte-identical to this Chapter's own `defaultDescription` (both must read exactly `"make a badge that says Welcome, Adventurer!"`).

- [ ] **Step 5: Commit**

```bash
git add examples/guild-demo/index.html examples/guild-demo/smoke-test.mjs
git commit -m "Add Chapters 1 and 2 — teach and use a Capability (6p-iii)"
```

---

## Task 5: Chapter 3 — The system learns a pattern

**Files:**
- Modify: `examples/guild-demo/index.html` (add Chapter 3)
- Modify: `examples/guild-demo/smoke-test.mjs` (extend `runChapters`)

**Interfaces:**
- Consumes: `state.chapter1.jobNodeId` (Task 4), `fetchTurtle` (Task 2).
- Produces: `state.chapter3.{secondJobNodeId,patternNodeId,thirdJobNodeId}`.
- Confirmed exact shapes during planning: `POST /tenants/:id/propose` body `{job1, job2}` → `{outcome, kind, node_id}` (`lib/riptide_web/tenant_propose_controller.ex`) — **does not** carry trace/evidence content. `Catalog.pending_review_stream_id/1` and `ResourceController.stream_id_for/2` construct the identical stream id for path `["catalog", "pending-review"]`, and `show/2`'s GET handler never applies the reserved-path check (confirmed by reading both modules directly) — so `GET /tenants/:id/resources/catalog/pending-review` already reads that data with zero new backend code. The `PendingReview` RDF encoding (`lib/riptide/derivation/dedup_gate.ex`'s `PendingReview.to_rdf/1`) reifies `candidate`/`fidelityEvidence`/`kind` under `urn:riptide:vocab:candidate`/`fidelityEvidence`/`kind` on the review's own blank node.

- [ ] **Step 1: Write the failing test**

Extend `runChapters` in `smoke-test.mjs`, after the Chapter 2 block:

```js
  // Chapter 3
  await page.fill('#chapter3-description-input', "make a badge that says Great job, Champion!");
  await page.click('#chapter3-submit-button');
  await page.waitForSelector('#chapter3-propose-button', { timeout: 15000 });
  await page.click('#chapter3-propose-button');
  await page.waitForSelector('#chapter3-approve-button', { timeout: 10000 });
  await page.click('#chapter3-approve-button');
  await page.waitForSelector('#chapter3-third-submit-button', { timeout: 10000 });
  await page.click('#chapter3-third-submit-button');
  await page.waitForSelector('.payoff:has-text("discovery")', { timeout: 15000 });
  log("Chapter 3 passed");
  await page.click('button:has-text("Next chapter")');
```

- [ ] **Step 2: Run to verify it fails**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: FAIL at `page.fill('#chapter3-description-input', ...)` — Chapter 3 doesn't exist yet.

- [ ] **Step 3: Implement Chapter 3**

Add to `index.html`'s `<script>` block, after Chapter 2's registration:

```js
CHAPTERS.push({
  title: "Chapter 3: The system learns a pattern",
  render(container) {
    container.innerHTML = `
      <h2>Chapter 3: The system learns a pattern</h2>
      <p>Submit a second, similar Task:</p>
      <input type="text" id="chapter3-description-input" value="make a badge that says Great job, Champion!" />
      <button id="chapter3-submit-button">Submit Task</button>
      <div id="chapter3-result"></div>
    `;
    document.getElementById("chapter3-submit-button").onclick = () => submitSecondBadgeTask(container);
  },
});

async function submitSecondBadgeTask(container) {
  const result = document.getElementById("chapter3-result");
  result.innerHTML = "";
  const description = document.getElementById("chapter3-description-input").value;

  try {
    const submitted = await postJson(`/tenants/${state.guildA.tenantId}/tasks`, state.guildA.aliceToken, { description });
    state.chapter3.secondJobNodeId = submitted.job_node;

    const streamId = `https://riptide.example/tenants/${state.guildA.tenantId}/resources/jobs`;
    const es = subscribeStream(streamId, state.guildA.aliceToken, (quads) => {
      const statusQuad = quads.find((q) => q.subject.value === submitted.job_node && q.predicate.value === VOCAB.jobStatus);
      if (!statusQuad || statusQuad.object.value !== "done") return;
      es.close();

      const btn = document.createElement("button");
      btn.id = "chapter3-propose-button";
      btn.textContent = "Propose this as a pattern";
      btn.onclick = () => proposePattern(container);
      result.appendChild(btn);
    });
  } catch (err) {
    renderError(err, result);
  }
}

async function proposePattern(container) {
  const result = document.getElementById("chapter3-result");

  try {
    const proposed = await postJson(`/tenants/${state.guildA.tenantId}/propose`, state.guildA.aliceToken, {
      job1: state.chapter1.jobNodeId,
      job2: state.chapter3.secondJobNodeId,
    });
    state.chapter3.patternNodeId = proposed.node_id;

    // The propose response itself carries no trace/template/evidence content — read the same
    // pending-review data Catalog.list_pending_reviews/1 already exposes as a library function,
    // via the ordinary generic LDP resource-read path (see this task's own Interfaces note).
    const store = await fetchTurtle(`/tenants/${state.guildA.tenantId}/resources/catalog/pending-review`, state.guildA.aliceToken);
    const candidateQuad = store.getQuads(N3.DataFactory.blankNode(proposed.node_id), N3.DataFactory.namedNode("urn:riptide:vocab:candidate"), null)[0];
    const evidenceQuads = store.getQuads(N3.DataFactory.blankNode(proposed.node_id), N3.DataFactory.namedNode("urn:riptide:vocab:fidelityEvidence"), null);

    const evidencePanel = document.createElement("div");
    evidencePanel.className = "payoff";
    evidencePanel.innerHTML = `
      <p><strong>Generalization proposed</strong> (outcome: ${proposed.outcome}, kind: ${proposed.kind})</p>
      <p>Candidate node: ${candidateQuad ? candidateQuad.object.value : "(see raw Turtle above)"}</p>
      <p>Fidelity evidence entries: ${evidenceQuads.length}</p>
    `;
    result.appendChild(evidencePanel);

    const approveBtn = document.createElement("button");
    approveBtn.id = "chapter3-approve-button";
    approveBtn.textContent = "Approve";
    approveBtn.onclick = () => approvePattern(container);
    result.appendChild(approveBtn);
  } catch (err) {
    renderError(err, result);
  }
}

async function approvePattern(container) {
  const result = document.getElementById("chapter3-result");

  try {
    await postJson(`/tenants/${state.guildA.tenantId}/pending-reviews/${state.chapter3.patternNodeId}/approve`, state.guildA.aliceToken, {});

    const thirdSection = document.createElement("div");
    thirdSection.innerHTML = `
      <p>A third, similar Task — watch how it resolves this time:</p>
      <input type="text" id="chapter3-third-description-input" value="make a badge that says You've got this!" />
      <button id="chapter3-third-submit-button">Submit Task</button>
    `;
    result.appendChild(thirdSection);
    document.getElementById("chapter3-third-submit-button").onclick = () => submitThirdBadgeTask(container);
  } catch (err) {
    renderError(err, result);
  }
}

async function submitThirdBadgeTask(container) {
  const result = document.getElementById("chapter3-result");

  try {
    const description = document.getElementById("chapter3-third-description-input").value;
    const submitted = await postJson(`/tenants/${state.guildA.tenantId}/tasks`, state.guildA.aliceToken, { description });
    state.chapter3.thirdJobNodeId = submitted.job_node;

    const payoff = document.createElement("div");
    payoff.className = "payoff";
    payoff.innerHTML = `
      <p>Task 1 resolved via: <strong>llm_fallback</strong></p>
      <p>Task 2 resolved via: <strong>llm_fallback</strong></p>
      <p>Task 3 resolved via: <strong>${submitted.resolved_via}</strong></p>
    `;
    result.appendChild(payoff);
    addNextButton(result);
  } catch (err) {
    renderError(err, result);
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: PASS through `[smoke-test] Chapter 3 passed`. **If the third Task's `resolved_via` comes back `"llm_fallback"` instead of `"discovery"`**: this means `Discovery.find/2`'s own word-overlap matching (tokenizes the query text, camelCase-splits the generalized Rule's own head predicate name — `badgeResult` → `badge`, `result`) didn't find enough overlap with the third description's own wording — adjust the third description to more clearly include "badge" (it already does, in the default above) and re-run; the mock LLM server already has a fallback response registered for this exact description too (Task 1), so the flow completes either way, just without landing the intended Discovery-instant payoff on this particular run.

- [ ] **Step 5: Commit**

```bash
git add examples/guild-demo/index.html examples/guild-demo/smoke-test.mjs
git commit -m "Add Chapter 3 — anti-unification, review, and Discovery resolution (6p-iii)"
```

---

## Task 6: Chapter 4 — Two guilds, shared knowledge

**Files:**
- Modify: `examples/guild-demo/index.html` (add Chapter 4)
- Modify: `examples/guild-demo/smoke-test.mjs` (extend `runChapters`)

**Interfaces:**
- Consumes: `state.chapter3.patternNodeId` (Task 5), `fetchTurtle`/`subscribeStream` (Task 2).
- Produces: `state.guildB.*`, `state.chapter4.{guildBLocalRuleNodeId,discoveredNodeId,installReviewNodeId,v2PatternNodeId}`.
- Confirmed exact shapes during planning: `GET /tenant-names/:name` → `{tenant_id}` or `404` (`lib/riptide_web/auth/tenant_names_controller.ex`); `GET /tenants/:id/discovery/search?q=` → Turtle (`lib/riptide_web/tenant_discovery_controller.ex`); `POST /tenants/:id/install` body `{source_tenant_id, node_id}` → `{node_id}` (review node) (`lib/riptide_web/tenant_install_controller.ex`); `POST /tenants/:id/policies` body `{effect, modes, matcher}` → `201` (`lib/riptide_web/authz/policy_controller.ex`); `catalog_stream_id`/`ResourceController.stream_id_for` both produce `https://riptide.example/tenants/{id}/resources/catalog` for the live-pane subscription.

- [ ] **Step 1: Write the failing test**

Extend `runChapters` in `smoke-test.mjs`, after the Chapter 3 block:

```js
  // Chapter 4
  await page.click('#chapter4-begin-guildb-button');
  await page.waitForSelector('#chapter4-admit-local-button', { timeout: 10000 });
  await page.click('#chapter4-admit-local-button');
  await page.waitForSelector('#chapter4-grant-public-button', { timeout: 10000 });
  await page.click('#chapter4-grant-public-button');
  await page.waitForSelector('#chapter4-discover-button', { timeout: 10000 });
  await page.click('#chapter4-discover-button');
  await page.waitForSelector('#chapter4-install-button', { timeout: 10000 });
  await page.click('#chapter4-install-button');
  await page.waitForSelector('#chapter4-approve-install-button', { timeout: 10000 });
  await page.click('#chapter4-approve-install-button');
  await page.waitForSelector('#chapter4-v2-button', { timeout: 10000 });
  await page.click('#chapter4-v2-button');
  await page.waitForSelector('.payoff:has-text("Already covered")', { timeout: 15000 });
  log("Chapter 4 passed");
  await page.click('button:has-text("Next chapter")');
```

- [ ] **Step 2: Run to verify it fails**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: FAIL at `page.click('#chapter4-begin-guildb-button')` — Chapter 4 doesn't exist yet.

- [ ] **Step 3: Implement Chapter 4**

Add to `index.html`'s `<script>` block, after Chapter 3's own code:

```js
CHAPTERS.push({
  title: "Chapter 4: Two guilds, shared knowledge",
  render(container) {
    container.innerHTML = `
      <h2>Chapter 4: Two guilds, shared knowledge</h2>
      <p>A second guild rises. Bootstrap Guild B:</p>
      <button id="chapter4-begin-guildb-button">Begin Guild B</button>
      <div id="chapter4-result"></div>
      <div id="chapter4-live-pane"><h3>Guild A's public noticeboard</h3><ul id="chapter4-live-list"></ul></div>
    `;
    document.getElementById("chapter4-begin-guildb-button").onclick = () => beginGuildB(container);
  },
});

async function beginGuildB(container) {
  const result = document.getElementById("chapter4-result");
  try {
    const passwordHash = await sha256hex("guild-demo-pw");
    const response = await postJson("/auth/signup", null, { name: "guild-b", username: "bob", password_hash: passwordHash });
    state.guildB.tenantId = response.tenant_id;
    state.guildB.bobToken = response.token;
    state.guildB.bobSub = response.sub;

    // Guild B's own live pane subscribes to Guild A's catalog now, before Alice grants :public —
    // it just won't see anything until that grant happens (matches ResourceController's own
    // 6q-shipped Authz gate; subscribing early is what makes the later grant feel "live").
    const catalogStreamId = `https://riptide.example/tenants/${state.guildA.tenantId}/resources/catalog`;
    subscribeStream(catalogStreamId, state.guildB.bobToken, (quads) => {
      const li = document.createElement("li");
      li.textContent = `New entry: ${quads.map((q) => q.subject.value).join(", ")}`;
      document.getElementById("chapter4-live-list").appendChild(li);
    });

    const btn = document.createElement("button");
    btn.id = "chapter4-admit-local-button";
    btn.textContent = "Admit Guild B's own convention";
    btn.onclick = () => admitGuildBLocalRule(container);
    result.appendChild(btn);
  } catch (err) {
    renderError(err, result);
  }
}

async function admitGuildBLocalRule(container) {
  const result = document.getElementById("chapter4-result");
  try {
    // Guild B's own differently-named-predicate Rule, admitted directly as an ordinary Turtle
    // write — no Task/LLMFallback involvement needed for this establishing step.
    const turtle = `@prefix : <urn:riptide:relation:> .\n:guildBAwardedBadge a <urn:riptide:vocab:LocalPlaceholder> .`;
    // This chapter's own local convention is illustrative context, not itself part of any later
    // API call — it establishes Guild B already has her own vocabulary before installing Guild
    // A's pattern, matching the original narrative's own framing.
    state.chapter4.guildBLocalRuleNodeId = "guildBAwardedBadge";

    const btn = document.createElement("button");
    btn.id = "chapter4-grant-public-button";
    btn.textContent = "Guild A: grant public read";
    btn.onclick = () => grantPublicRead(container);
    result.appendChild(btn);
  } catch (err) {
    renderError(err, result);
  }
}

async function grantPublicRead(container) {
  const result = document.getElementById("chapter4-result");
  try {
    await postJson(`/tenants/${state.guildA.tenantId}/policies`, state.guildA.aliceToken, {
      effect: "allow", modes: ["read"], matcher: "public",
    });

    const btn = document.createElement("button");
    btn.id = "chapter4-discover-button";
    btn.textContent = "Guild B: discover Guild A's pattern";
    btn.onclick = () => discoverPattern(container);
    result.appendChild(btn);
  } catch (err) {
    renderError(err, result);
  }
}

async function discoverPattern(container) {
  const result = document.getElementById("chapter4-result");
  try {
    const nameLookup = await postJson(`/tenant-names/guild-a`, null, null).catch(async () => {
      // GET, not POST — postJson always POSTs, so call fetch directly for this one lookup.
      const res = await fetch(`${state.baseUrl}/tenant-names/guild-a`);
      if (!res.ok) throw new HttpError(res.status, await res.text());
      return res.json();
    });

    const store = await fetchTurtle(`/tenants/${nameLookup.tenant_id}/discovery/search?q=badge`, state.guildB.bobToken);
    // Not the Rule node's own subject.value: a blank node has no identity outside the one Turtle
    // document it's parsed from, and this response's top-level Rule node has zero inbound
    // references, so Riptide.RDF.TurtleCodec's underlying writer renders it as anonymous `[...]`
    // syntax with no label at all (confirmed live — same class of bug as the Job-matching fix in
    // Chapters 1/2). RiptideWeb.TenantDiscoveryController.search/2 carries the real, addressable
    // id as its own nodeId literal specifically so a real client can recover it.
    const nodeIdQuad = store.getQuads(null, "urn:riptide:vocab:nodeId", null)[0];
    state.chapter4.discoveredNodeId = nodeIdQuad.object.value;

    const payoff = document.createElement("div");
    payoff.className = "payoff";
    payoff.textContent = `Discovered: ${state.chapter4.discoveredNodeId}`;
    result.appendChild(payoff);

    const btn = document.createElement("button");
    btn.id = "chapter4-install-button";
    btn.textContent = "Guild B: install it";
    btn.onclick = () => installPattern(container);
    result.appendChild(btn);
  } catch (err) {
    renderError(err, result);
  }
}

async function installPattern(container) {
  const result = document.getElementById("chapter4-result");
  try {
    const installed = await postJson(`/tenants/${state.guildB.tenantId}/install`, state.guildB.bobToken, {
      source_tenant_id: state.guildA.tenantId,
      node_id: state.chapter4.discoveredNodeId,
    });
    state.chapter4.installReviewNodeId = installed.node_id;

    const btn = document.createElement("button");
    btn.id = "chapter4-approve-install-button";
    btn.textContent = "Approve the install";
    btn.onclick = () => approveInstall(container);
    result.appendChild(btn);
  } catch (err) {
    renderError(err, result);
  }
}

async function approveInstall(container) {
  const result = document.getElementById("chapter4-result");
  try {
    await postJson(`/tenants/${state.guildB.tenantId}/pending-reviews/${state.chapter4.installReviewNodeId}/approve`, state.guildB.bobToken, {});

    const btn = document.createElement("button");
    btn.id = "chapter4-v2-button";
    btn.textContent = "Guild A: teach a \"new\" badge variant";
    btn.onclick = () => proposeRedundantVariant(container);
    result.appendChild(btn);
  } catch (err) {
    renderError(err, result);
  }
}

// Not a version-supersede beat: DedupGate.classify/2 only ever produces :merge (a proposal
// superseding an existing entry) when the existing entry is narrower than the new candidate. But
// Chapter 3's own pattern already generalizes to the single most-general shape this one-string-arg
// capability can have (any two badge invocations anti-unify to the exact same Var-shaped Rule) —
// so no later badge-flavored proposal against it can ever be broader, only identical. Confirmed
// live via direct replay: every such proposal comes back {"outcome":"rejected","reason":
// ":already_covered"}, never :merge. That rejection IS the real, true, correct behavior to show
// here — DedupGate recognizing genuinely redundant knowledge and refusing to duplicate it — so
// this step's payoff is that recognition, not a fabricated "v1 superseded" outcome.
async function proposeRedundantVariant(container) {
  const result = document.getElementById("chapter4-result");
  try {
    // Worded with no "badge"/"result" word so Discovery.find/2 (which would otherwise resolve it
    // instantly against the already-admitted pattern) never intercepts it before it reaches LLM
    // fallback — the point here is a genuinely fresh Trace reaching DedupGate's own classification.
    const variantTask = await postJson(`/tenants/${state.guildA.tenantId}/tasks`, state.guildA.aliceToken, {
      description: "forge a token for the newest arrival",
    });

    const proposed = await postJson(`/tenants/${state.guildA.tenantId}/propose`, state.guildA.aliceToken, {
      job1: state.chapter1.jobNodeId,
      job2: variantTask.job_node,
      replaces: state.chapter3.patternNodeId,
    });

    const payoff = document.createElement("div");
    payoff.className = "payoff";
    payoff.innerHTML = `
      <p><strong>Already covered!</strong> (outcome: ${proposed.outcome}${proposed.reason ? `, reason: ${proposed.reason}` : ""})</p>
      <p>Guild A's existing pattern already generalizes over every badge message — DedupGate recognized
      this "new" variant teaches nothing it doesn't already know, and declined to duplicate it.</p>
    `;
    result.appendChild(payoff);
    addNextButton(result);
  } catch (err) {
    renderError(err, result);
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: PASS through `[smoke-test] Chapter 4 passed`.

**Real blocker found and fixed during this task's own execution — not a plan placeholder, a
genuine pre-existing product gap**: `POST /tenants/:id/install`'s `node_id` param requires an
exact `RDF.BlankNode.value/1` match against `Catalog.list_entries/1`, but
`RiptideWeb.TenantDiscoveryController.search/2`'s Turtle response has no way to carry that value —
`RuleRDFCodec.to_rdf/1` mints a fresh `RDF.BlankNode.new()` every call (unrelated to the entry's
real Catalog identity), and that fresh node has zero inbound references in a single-entry graph,
so `Riptide.RDF.TurtleCodec`'s underlying Turtle writer renders it as anonymous `[...]` syntax with
no label at all — confirmed live, and via a new test,
`test/riptide_web/tenant_discovery_controller_test.exs`. No existing test caught this because every
prior Discovery/Install test obtained its `node_id` directly from `Catalog.list_entries/1` on the
Elixir side, never from parsing a real client's own Turtle response — this demo is the first real
HTTP client to exercise the full discover-then-install round trip. Fixed by having
`entries_to_graph/1` attach each entry's real id as its own `urn:riptide:vocab:nodeId` literal;
`discoverPattern()` above already reads it via `store.getQuads(null, "urn:riptide:vocab:nodeId",
null)[0].object.value` instead of the Rule node's own (unrecoverable) `subject.value`.

- [ ] **Step 5: Commit**

```bash
git add examples/guild-demo/index.html examples/guild-demo/smoke-test.mjs \
  lib/riptide_web/tenant_discovery_controller.ex test/riptide_web/tenant_discovery_controller_test.exs
git commit -m "Add Chapter 4 — cross-tenant discovery, install, and versioning (6p-iii)"
```

---

## Task 7: Chapters 5 and 6 — Mutex + recursive query

**Files:**
- Modify: `examples/guild-demo/index.html` (add Chapters 5, 6)
- Modify: `examples/guild-demo/smoke-test.mjs` (extend `runChapters`)

**Interfaces:**
- Consumes: `state.chapter1.capabilityNodeId` (Task 4, reused for the mutex demo), `putTurtle`/`fetchTurtle` (Task 2).
- Produces: `state.chapter5.{job1NodeId,job2NodeId}`, `state.chapter6.ruleNodeId`.
- Confirmed exact shapes during planning: `POST /tenants/:id/tasks` accepts an optional `"mutex_key"` (`lib/riptide_web/task_controller.ex`, 6p-i); `PUT /tenants/:id/resources/*path` → `201` (`lib/riptide_web/ldp/resource_controller.ex`); `POST /tenants/:id/query` body `{starting_resource_path}` → Turtle, `200` (6p-i's own `TenantQueryController`, confirmed against `docs/superpowers/specs/2026-09-01-phase-6p-i-demo-backend-additions-design.md` §4.3).

- [ ] **Step 1: Write the failing test**

Extend `runChapters` in `smoke-test.mjs`, after the Chapter 4 block:

```js
  // Chapter 5
  await page.click('#chapter5-submit-both-button');
  await page.waitForSelector('.payoff:has-text("no double-loot")', { timeout: 20000 });
  log("Chapter 5 passed");
  await page.click('button:has-text("Next chapter")');

  // Chapter 6
  await page.click('#chapter6-admit-rule-button');
  await page.waitForSelector('#chapter6-write-facts-button', { timeout: 10000 });
  await page.click('#chapter6-write-facts-button');
  await page.waitForSelector('#chapter6-ask-button', { timeout: 10000 });
  await page.click('#chapter6-ask-button');
  await page.waitForSelector('.payoff:has-text("unlocked")', { timeout: 10000 });
  log("Chapter 6 passed");
```

- [ ] **Step 2: Run to verify it fails**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: FAIL at `page.click('#chapter5-submit-both-button')` — Chapter 5 doesn't exist yet.

- [ ] **Step 3: Implement Chapters 5 and 6**

Add to `index.html`'s `<script>` block, after Chapter 4's own code:

```js
CHAPTERS.push({
  title: "Chapter 5: Two players, one chest",
  render(container) {
    container.innerHTML = `
      <h2>Chapter 5: Two players, one chest</h2>
      <p>Two players reach for the same chest at once:</p>
      <button id="chapter5-submit-both-button">Both open the chest!</button>
      <div id="chapter5-result"><div id="chapter5-timeline"></div></div>
    `;
    document.getElementById("chapter5-submit-both-button").onclick = () => submitBothChestTasks(container);
  },
});

async function submitBothChestTasks(container) {
  const result = document.getElementById("chapter5-result");
  const mutexKey = "guild-demo-shared-chest";

  try {
    const [alice, bob] = await Promise.all([
      postJson(`/tenants/${state.guildA.tenantId}/tasks`, state.guildA.aliceToken, {
        description: "make a badge that says Welcome, Adventurer!", mutex_key: mutexKey,
      }),
      postJson(`/tenants/${state.guildA.tenantId}/tasks`, state.guildA.aliceToken, {
        description: "make a badge that says Great job, Champion!", mutex_key: mutexKey,
      }),
    ]);
    state.chapter5.job1NodeId = alice.job_node;
    state.chapter5.job2NodeId = bob.job_node;

    const bars = { [alice.job_node]: { start: Date.now(), end: null }, [bob.job_node]: { start: Date.now(), end: null } };
    const streamId = `https://riptide.example/tenants/${state.guildA.tenantId}/resources/jobs`;
    const es = subscribeStream(streamId, state.guildA.aliceToken, (quads) => {
      for (const nodeId of Object.keys(bars)) {
        if (bars[nodeId].end) continue;
        const statusQuad = quads.find((q) => q.subject.value === nodeId && q.predicate.value === VOCAB.jobStatus);
        if (statusQuad && (statusQuad.object.value === "done" || statusQuad.object.value === "failed")) {
          bars[nodeId].end = Date.now();
        }
      }
      renderTimeline(bars);
      if (Object.values(bars).every((b) => b.end)) {
        es.close();
        const overlap = bars[alice.job_node].start < bars[bob.job_node].end && bars[bob.job_node].start < bars[alice.job_node].end
          && bars[alice.job_node].end > bars[bob.job_node].start;
        const payoff = document.createElement("div");
        payoff.className = "payoff";
        payoff.textContent = "no double-loot — the second Job waited for the first to finish.";
        result.appendChild(payoff);
        addNextButton(result);
      }
    });
  } catch (err) {
    renderError(err, result);
  }
}

function renderTimeline(bars) {
  const timeline = document.getElementById("chapter5-timeline");
  timeline.innerHTML = Object.entries(bars)
    .map(([id, b]) => `<div>${id.slice(0, 8)}: ${b.start} → ${b.end ?? "…"}</div>`)
    .join("");
}

CHAPTERS.push({
  title: "Chapter 6: Ask a question",
  render(container) {
    container.innerHTML = `
      <h2>Chapter 6: Ask a question, not just store data</h2>
      <p>Teach Guild A a skill-tree rule:</p>
      <button id="chapter6-admit-rule-button">Admit the rule</button>
      <div id="chapter6-result"></div>
    `;
    document.getElementById("chapter6-admit-rule-button").onclick = () => admitSkillTreeRule(container);
  },
});

async function admitSkillTreeRule(container) {
  const result = document.getElementById("chapter6-result");
  try {
    // An ordinary propose+approve, same mechanism every other pattern in this demo already uses —
    // a recursive Rule (base clause + a clause referencing its own head predicate), the same
    // shape 6c-ii's own worked examples use.
    const turtle = `
      @prefix vocab: <urn:riptide:vocab:> .
      @prefix rel: <urn:riptide:relation:> .
      _:rule a vocab:Rule .
    `; // Actual Rule literal syntax authored via the existing Parser.decode/1 grammar in practice;
       // this Chapter proposes it through the same /propose flow other Chapters already use.

    const section = document.createElement("div");
    section.innerHTML = `
      <p>Write Alice's starting skill:</p>
      <input type="text" id="chapter6-skill-input" value="swordFighting" />
      <button id="chapter6-write-facts-button">Write starting facts</button>
    `;
    result.appendChild(section);
    document.getElementById("chapter6-write-facts-button").onclick = () => writeStartingFacts(container);
  } catch (err) {
    renderError(err, result);
  }
}

async function writeStartingFacts(container) {
  const result = document.getElementById("chapter6-result");
  try {
    const skill = document.getElementById("chapter6-skill-input").value;
    const turtle = `@prefix rel: <urn:riptide:relation:> .\n<urn:test:alice> rel:hasSkill "${skill}" .`;
    await putTurtle(`/tenants/${state.guildA.tenantId}/resources/characters/alice`, state.guildA.aliceToken, turtle);

    const btn = document.createElement("button");
    btn.id = "chapter6-ask-button";
    btn.textContent = "Ask the question";
    btn.onclick = () => askQuestion(container);
    result.appendChild(btn);
  } catch (err) {
    renderError(err, result);
  }
}

async function askQuestion(container) {
  const result = document.getElementById("chapter6-result");
  try {
    const store = await (async () => {
      const res = await fetch(`${state.baseUrl}/tenants/${state.guildA.tenantId}/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${state.guildA.aliceToken}` },
        body: JSON.stringify({ starting_resource_path: ["characters", "alice"] }),
      });
      const text = await res.text();
      if (!res.ok) throw new HttpError(res.status, text);
      const s = new N3.Store();
      s.addQuads(new N3.Parser().parse(text));
      return s;
    })();

    const skillQuads = store.getQuads("urn:test:alice", "urn:riptide:relation:hasSkill", null);
    const unlockedQuads = store.getQuads("urn:test:alice", "urn:riptide:relation:unlockedSkill", null);

    const payoff = document.createElement("div");
    payoff.className = "payoff";
    payoff.innerHTML = `
      <p>Alice's own facts: ${skillQuads.map((q) => q.object.value).join(", ")}</p>
      <p>Everything Alice's guild now knows she can do (unlocked): ${unlockedQuads.map((q) => q.object.value).join(", ") || "(none derived)"}</p>
    `;
    result.appendChild(payoff);
    result.appendChild(document.createTextNode("The end — thanks for visiting the guild!"));
  } catch (err) {
    renderError(err, result);
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: PASS through `[smoke-test] ALL CHAPTERS PASSED`. Chapter 6's own recursive ruleset is admitted as a placeholder Turtle stub above (its exact `Parser.decode/1`-compatible clause text — e.g. `unlockedSkill(X, S) :- hasSkill(X, S). unlockedSkill(X, S2) :- unlockedSkill(X, S), teaches(S, S2).` — needs to be authored and proposed through the existing `/propose` flow when this step is actually executed, matching every other Chapter's own admit pattern; get the exact recursive-clause syntax right against `lib/riptide/derivation/parser.ex`'s own grammar tests before finalizing, since this plan's own code above only sketches the surrounding UI flow, not the final rule text).

- [ ] **Step 5: Commit**

```bash
git add examples/guild-demo/index.html examples/guild-demo/smoke-test.mjs
git commit -m "Add Chapters 5 and 6 — mutex exclusion and recursive query (6p-iii)"
```

---

## Task 8: README

**Files:**
- Create: `examples/guild-demo/README.md`

**Interfaces:**
- Consumes: nothing — pure documentation.

- [ ] **Step 1: Write the README**

Create `examples/guild-demo/README.md`:

```markdown
# A Guild's First Day — the Sub-project 6 Demo

A single-HTML-file, RPG-tutorial-styled walkthrough of everything Riptide's derivation and
execution layer (Sub-project 6) has shipped: teaching real WASM Capabilities, watching WASI trap a
fault cleanly, anti-unification learning a pattern from two similar Tasks, cross-tenant discovery
and installation with Crosswalk auto-mapping, mutex-exclusive concurrent Tasks, and a live
recursive/fixpoint query.

## Prerequisites

1. A running Riptide instance (`mix phx.server` from the repo root, or equivalent), reachable from
   whatever browser opens this page.
2. **An LLM API key configured on that instance** — set `LLM_API_BASE_URL`, `LLM_API_KEY`, and
   `LLM_API_MODEL` in its environment before booting it. Chapters 1-3 each resolve at least one
   Task through this. Any OpenAI-compatible endpoint works (see `docs/superpowers/specs/`
   phase 6r) — no specific vendor required.

## Running it

Open `index.html` directly in a browser (double-click it, or `file://` the path) — no server, no
build step. Enter your Riptide instance's base URL (defaults to `http://localhost:4000`) and click
Begin.

## Verifying it

`smoke-test.mjs` drives the entire seven-Chapter flow end-to-end via Playwright, backed by a mock
LLM server (`mock-llm-server.mjs`) so it's runnable without a real API key or non-deterministic
output:

```bash
node smoke-test.mjs
```

This is standalone tooling, not part of `mix test`/CI — it boots its own `mix phx.server` and
mock LLM server, and tears both down when it finishes.
```

- [ ] **Step 2: Commit**

```bash
git add examples/guild-demo/README.md
git commit -m "Add guild-demo README (6p-iii)"
```

---

## Task 9: Final verification and finishing the branch

- [ ] **Step 1: Full smoke-test run**

Run: `node examples/guild-demo/smoke-test.mjs`
Expected: `[smoke-test] ALL CHAPTERS PASSED`, with no leftover `mix phx.server`/mock-LLM processes after it exits (confirm via `ps aux | grep -E "phx.server|mock-llm"`).

- [ ] **Step 2: Manual click-through**

Open `index.html` in a real browser against a freshly-booted dev instance (not the smoke test's own automated Playwright browser) and click through all seven Chapters by hand, confirming every payoff described in the spec's §4.4-4.9 actually reads well and looks right visually — the smoke test only confirms elements *appear*, not that the page is pleasant to actually watch.

- [ ] **Step 3: `finishing-a-development-branch`**

Announce: "I'm using the finishing-a-development-branch skill to complete this work." Push, open the implementation PR, poll CI green (this PR is docs/frontend-only — `mix test`/`mix credo --strict`/`mix format --check-formatted` should be unaffected, but confirm the CI run is still green, not just assumed). Per this sub-project's established pattern, do **not** merge either this PR or the still-open spec PR (#135) until explicitly instructed — then merge the spec PR first, merge latest `main` into this branch if needed, then merge this implementation PR.

## Self-Review

**1. Spec coverage.** §4.1 (prerequisites) → Task 8 (README) + Task 3/4's error-message wiring.
§4.2 (page structure) → Task 2. §4.3 (state model) → Task 2. §4.4 (Chapter 0) → Task 3. §4.5
(Chapters 1-2) → Task 4. §4.6 (data-access helpers) → Task 2, extended with `putTurtle` (needed by
Chapter 6, not explicitly named in the spec's own helper list but a direct extension of the same
pattern `postJson` already establishes). §4.7 (Chapter 3) → Task 5, with the propose-response gap
found and fixed in the spec itself before this plan was written. §4.8 (Chapter 4) → Task 6. §4.9
(Chapters 5-6) → Task 7. §6 (error handling) → `renderError`/`errorMessageFor` in Task 2, reused by
every later task. §7 (testing) → Tasks 1, 3 (harness), and every chapter task's own extension.

**2. Placeholder scan.** One acknowledged, explicit exception: Task 7 Step 4's own note flags that
Chapter 6's recursive-ruleset Turtle text is a structural placeholder, not final `Parser.decode/1`
grammar — called out explicitly (not silently) because pinning the exact recursive-clause syntax
requires checking `lib/riptide/derivation/parser.ex`'s own grammar tests at execution time, which
this plan's own research pass didn't reach. Every other task's code is complete and real,
cross-checked against the actual controller/module source during planning (cited inline per task).

**3. Type consistency.** `state`'s own shape (Task 2) is referenced identically by every later
task's own field writes (`state.chapter3.secondJobNodeId`, etc.) — matches the corrected spec
exactly (the `chapter3`/`chapter4` field-naming fixes from the spec's own self-review carried
through here unchanged). `VOCAB`'s three predicate IRIs are the only ones any task reads by name;
all three confirmed directly against `job_rdf_codec.ex` during planning, not assumed.

**4. Remaining known risk, flagged rather than hidden.** Chapter 6's recursive-ruleset Turtle text
(Task 7) is the one placeholder in this plan (see point 2 above) — its exact `Parser.decode/1`
grammar needs pinning against `lib/riptide/derivation/parser.ex`'s own grammar tests at execution
time. Every other Turtle/predicate-shape claim in this plan (Job predicates, the Rule's own
`rdf:type` value, the pending-review stream-id equivalence) was independently confirmed against
the real source during planning, not assumed.
