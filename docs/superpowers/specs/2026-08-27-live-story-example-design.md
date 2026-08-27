# "The Story So Far" — a joyful Riptide example

## Context & motivation

Riptide has no example application showing what it's actually like to *use* — every existing
artifact (tests, benchmarks, k8s manifests) targets developers of Riptide itself, not developers
building on top of it. This adds one small, delightful, checked-in example (`examples/live-story/`)
from the perspective of a first-time user: a single shared story that anyone visiting a page can
add the next line to, with every open tab watching it grow live. The goal is to make Riptide's real
differentiators — live event delivery, append-only history, resumable cursors, and the fact that
it's genuinely Linked Data under the hood — *felt*, not just documented.

## Scope

- A small, permissive CORS plug on `RiptideWeb.Endpoint`, needed for any browser-based pod client
  (this example is the first consumer, but the gap is real and general — Solid-style pod clients
  are inherently cross-origin from their pod by design, and Riptide currently supports none of
  this).
- `examples/live-story/`: a static `index.html` + `app.js` + `style.css` (no build step, no
  framework) implementing the experience below, plus `setup.exs` (a `mix run` script) and a short
  `README.md` explaining how to try it.
- Manual/scripted verification that the live cross-tab experience actually works (two clients, one
  posts a line, the other sees it appear without refreshing).

## Out of scope

- Authentication/login of any kind — the whole point is zero-friction anonymous participation.
- Multiple concurrent stories/rooms — one single, permanent, global story for this version. (The
  data model doesn't preclude adding rooms later — each room would just be a different resource
  path — but it's not part of this pass.)
- Running the example against a remote/already-deployed Riptide instance that this repo's checkout
  doesn't control — `setup.exs` seeds the tenant's policy and opening line via Riptide's own Elixir
  API directly (`mix run`), which requires a local, in-repo checkout. Seeding a remote instance
  would need an HTTP-based, auth-appropriate bootstrap flow, which is a reasonable future extension
  but adds real complexity this version doesn't need.
- Deleting/moderating lines, editing the opening line, rate-limiting submissions.

## The experience

A visitor opens `index.html` (literally double-clicking the file works — no server needed, thanks
to the CORS change below) against a locally-running Riptide (`mix phx.server`, already seeded via
`setup.exs`). They see a warm, storybook-styled page with the story so far, opening on a seeded
first line (e.g. *"Once, in a kingdom made of tea and thunder, a fox found a door that wasn't there
yesterday."*), each line fading in with its author — a whimsical guest name randomly assigned to
that browser tab (e.g. "the Wandering Fox"), stored in `sessionStorage` so it stays stable across
reconnects within the same tab. A text input at the bottom lets them add the next line. The moment
they submit, it appears on their own page *and* on every other open tab, live, with no refresh. A
small "peek at the data" toggle reveals the raw Turtle triples behind the latest line, making the
Linked Data underneath visible rather than a black box.

## Data model

One LDP resource holds the whole story: `/tenants/story-demo/resources/the-story`. Deliberately a
single resource with an accumulating graph, not Riptide's POST-to-container/child-resource
pattern — each line is small, immutable, and never independently addressed, so a growing sequence
of `PATCH` additions on one resource is both the simplest shape and the one that best shows off
Riptide's delta-event model.

Each line is a small entity within that graph, added via one `PATCH` (or, for the very first line
only, the initial `PUT` that creates the resource):

```turtle
<urn:uuid:8f14e45f-...> a schema:CreativeWork ;
  schema:text "Once, in a kingdom made of tea and thunder, a fox found a door that wasn't there yesterday." ;
  schema:author "the Wandering Fox" .
```

Real `schema.org` terms, not an invented throwaway vocabulary — small enough to cost nothing here,
and it's a better demonstration of actual Linked Data practice (reuse existing vocabularies) than
minting new predicates would be.

**No explicit ordering field.** The `PATCH` wire format is additions-only (Riptide's existing,
documented limitation — see `Riptide.Event.wire_payload/1`), which fits this use case exactly:
each event's payload *is* one complete new line, and the event stream's own sequence order *is*
the story's order. A client never needs to sort lines itself — it just needs to consume events in
the order the server delivers them.

## Client architecture

- **Loading the story**: subscribe to `GET /streams/<the-story's-stream_id>/subscribe` with
  `Last-Event-ID: 0`, requesting the full backlog from the beginning, then keep the connection open
  for live events. **Not implemented via the native `EventSource` API** — browsers only let
  `EventSource` set `Last-Event-ID` automatically, on its own automatic reconnects, never on the
  first connection, so there is no way to ask a fresh `EventSource` for backlog from cursor 0.
  Instead, `app.js` uses `fetch()` with a `ReadableStream` reader and a small hand-rolled
  `text/event-stream` parser (a few dozen lines: split on blank lines, parse `id:`/`data:`
  fields). This also makes the reconnect-with-last-seen-cursor loop explicit and visible rather
  than hidden inside a browser API — a deliberate choice, since Riptide's own resumable-cursor
  design (`Last-Event-ID` support, explicitly called out in the top-level README) is one of the
  things this example exists to show off. On a dropped connection, reconnect with
  `Last-Event-ID: <highest sequence seen>` after a fixed 1-second backoff.
- **Submitting a line**: `PATCH` the story resource with
  `{"additions": "<turtle for the new line>", "removals": ""}`, `Content-Type: application/json` —
  the exact contract `RiptideWeb.LDP.ResourceController.patch/2` already expects. `app.js` builds
  the Turtle snippet from a fixed template (own guest name + escaped text + a client-generated
  `urn:uuid:` for the line) — no RDF library needed client-side.
- **Rendering**: each backlog/live event's Turtle payload is decoded (a tiny regex-based extraction
  of the two literal values is enough — full Turtle parsing isn't needed for a fixed, known shape)
  and appended to the page with a fade-in transition.
- **Guest name**: on first load, pick one adjective+noun pair from a small fixed word list, store
  it in `sessionStorage`.

## Riptide-side change: CORS

A new plug, mounted in `RiptideWeb.Endpoint` early in the pipeline (before `Plug.Parsers`, so an
`OPTIONS` preflight never reaches — and 404s from — the router), using the
[`cors_plug`](https://hex.pm/packages/cors_plug) library rather than hand-rolling: CORS
header/preflight handling has real security-relevant edge cases (credentialed vs. wildcard origins,
exact preflight semantics), and this project reaches for a well-vetted dependency over hand-rolling
specifically in cases like this — contrast Phase 5b's hand-rolled JSON log formatter, which is not
security-sensitive in the same way.

Configuration: `origin: "*"` (no credentials — Riptide's own auth is a Bearer token in a header,
never a cookie, so a wildcard origin has no credential-leak implication), `methods: ["GET", "PUT",
"PATCH", "DELETE", "POST", "OPTIONS"]` (exactly LDP's own verbs), `headers: ["Authorization",
"Content-Type", "Last-Event-ID"]`. Applies to every route uniformly — no reason to scope it
narrower than "the whole API is meant to be called cross-origin," which is the actual, general gap
being closed here, not an example-specific carve-out.

## Setup script (`examples/live-story/setup.exs`)

A `mix run examples/live-story/setup.exs`, run from a Riptide checkout with `mix phx.server`
already running (or about to run) against it — the same "talk to Riptide's own Elixir API
directly, bypassing HTTP" pattern this repo's own `test/bench/*_test.exs` scripts already
establish. It:

1. Seeds a `:public`, `[:read, :write]` policy for tenant `story-demo` via
   `Riptide.Authz.Store.Placement.add_policy/3` (same call every test/bench fixture in this repo
   already uses for anonymous-access seeding).
2. `PUT`s the opening line onto `/tenants/story-demo/resources/the-story` via
   `Riptide.Stream.StreamServer.append/2` directly (same pattern as
   `test/bench/http_server_test.exs`), so the story never starts genuinely empty.

Idempotent: safe to re-run (policy add is already idempotent server-side; the opening-line PUT is
only meaningful the first time, but re-running it just resets to the seeded opening line, which is
an acceptable, documented reset path for local dev use — not exposed as a public reset button in
the UI itself).

## Testing

- Riptide-side: a new test module for the CORS plug — asserts `Access-Control-Allow-Origin` is
  present on a normal `GET`/`PUT`/`PATCH` response, and that an `OPTIONS` preflight to an LDP route
  returns 200 with the expected `Access-Control-Allow-Methods`/`-Headers`, without reaching the
  router (i.e. without requiring auth/tenant resolution to succeed).
- The example itself has no automated test suite of its own (a static HTML/JS page, no build
  tooling) — verified instead by actually driving it: two real browser contexts (via Playwright,
  already available on this box) opening the same page, one submitting a line, the other observed
  to receive it live without a manual refresh. This is the acceptance criterion for the example
  working as designed, not just "the code compiles."
