# StreamLD + Riptide — Design

**Status:** Architecture approved 2026-08-22. Not yet implemented — this doc is the input to
an implementation plan (via the `writing-plans` process), not a plan itself.

## 1. Context and motivation

The original goal: build an event-driven alternative to
[Community Solid Server](https://github.com/CommunitySolidServer/CommunitySolidServer) (CSS) —
CSS is a synchronous request/response pipeline with real-time notifications bolted on as an
afterthought (a WebSocket channel type layered on top of the Solid Notifications Protocol).
We wanted a server built around events as the native primitive from the start, for
high-performance, real-time workloads.

This is exploratory/research work: the deliverable is a working prototype server we can
benchmark and iterate on, not a design doc alone.

## 2. Ecosystem placement

This work is not a standalone project — it incubates within
[OpenFASTER](https://openfaster.org), an existing suite of open standards (currently just
`mikadiv/`, an EU withholding-tax/dividend-reporting data-exchange schema). OpenFASTER intends
to grow into a cohesive standards *ecosystem*, not stay narrowly tax-domain-specific, and this
project — a domain-agnostic real-time event-streaming standard — is deliberately incubated
there rather than folded in as a tightly-coupled "module" like `mikadiv/`. The precedent is
CNCF's own maturity model (Sandbox → Incubating → Graduated): CloudEvents itself originated
inside a broader Serverless Working Group and was deliberately spun out into independent
governance once its core spec matured, rather than staying bundled. StreamLD should be free to
follow the same path later if it outgrows OpenFASTER; for now it stays under the
`OpenFASTER-Standard` GitHub org and on openfaster.org.

Two repos, deliberately separate so spec content and implementation code don't churn together:

- **`OpenFASTER-Standard/spec`** — gains a `streamld/` module directory (Bikeshed, same
  toolchain as `mikadiv/`). Spec content only.
- **`OpenFASTER-Standard/riptide`** (this repo) — the Elixir/Phoenix reference implementation.
  Proves the spec is buildable; becomes the interop/conformance test target.

## 3. Research summary

This design is the result of four rounds of deep research (fan-out web search + adversarial
verification), not first-principles guessing. Key findings, in the order they changed the
design:

1. **LDES (Linked Data Event Streams)** is the existing prior art for "event-sourced Solid
   pod" — real implementations exist (LDES-in-LDP, a CSS-based orchestrator, a peer-reviewed
   2022 paper). But LDES itself defines no real-time/push mechanism at all — it's pull/poll
   /traverse-only (GET-based TREE fragment traversal).
2. Investigating a real-time layer *on top of* LDES surfaced that **LDES's own ordering model
   is a genuine, self-acknowledged design wart**: ordering depends on a `timestampPath`
   property with two further tiebreak properties (`sequencePath`, `versionSequencePath`) for
   ties and out-of-order publishing. The spec's own editor consolidated five open GitHub issues
   into one trying to untangle "chronological order" vs. "version order" semantics that
   `timestampPath` was conflating. Even LDES's own reference client only implements
   `timestampPath` — the other two tiebreak properties have zero implementations.
3. **Professional event-sourcing systems (Kafka, EventStoreDB) independently converged on a
   different, simpler answer**: a single server-assigned monotonic sequence number per stream
   as the sole ordering primitive, no timestamps in the ordering path at all. The one plausible
   justification for LDES's timestamp-based approach (multi-producer aggregation without a
   single sequencing authority) did not survive adversarial verification — no confirmed benefit
   offsets the complexity.
4. **Decision: abandon LDES entirely** (no compatibility layer, no export projection). Build a
   clean, purpose-built event log: monotonic per-stream sequence number, RDF/JSON-LD payloads,
   real deltas via [RDF Patch](https://afs.github.io/rdf-delta/rdf-patch.html) instead of
   LDES's full-object-republish-per-version model (which has a measured, real storage cost;
   one delta-format alternative, Jelly-Patch, showed a 5.4x storage reduction in one measured
   workload).
5. **Confirmed: dropping LDES has no bearing on Solid/LDP compatibility.** LDP Basic Container
   support is a core `MUST` of the Solid Protocol itself, entirely independent of any
   notifications layer. Solid's own real-time layer (the Solid Notifications Protocol) contains
   zero references to LDES or TREE anywhere. LDES was never a required dependency of Solid —
   only an optional bolt-on some deployments chose to add.
6. **CloudEvents (CNCF) is the closest real-world template** for a clean-slate, professional
   event standard that achieved genuine multi-vendor adoption: one abstract core spec +
   independently-versioned Event Format docs + independently-versioned Protocol Binding docs +
   satellite specs (Subscriptions, a Primer) + per-language SDKs in separate repos. AsyncAPI
   independently converged on the same layering discipline (data format / stream discovery /
   subscribe-vs-publish direction / per-protocol bindings). StreamLD's spec structure (§4.4)
   follows this template directly.
7. For the transport layer specifically: **SSE is the only mainstream option with a native,
   browser-built-in resumption cursor** (`Last-Event-ID`); WebSocket and MQTT both leave
   resumption unspecified or absent. Server-to-server LDES-style replication turned out to be
   *genuinely unsolved* in the wider ecosystem (Kafka only appears as an ingestion path into a
   single server, never as federation between two servers) — this is real, novel
   standardization work, not something to copy from prior art.

## 4. Architecture

### 4.1 Core data model

- An event log per resource ("stream"), append-only.
- Ordering: a single **server-assigned monotonic sequence number per stream** — no
  timestamp-based ordering, no tiebreak properties.
- Payload: RDF, serialized as JSON-LD.
- Changes are represented as **deltas** (RDF Patch: explicit add/remove of triples), not
  full-object republishing — except the first event in a stream, which is necessarily a full
  snapshot.

### 4.2 Cursor model

- **Cursor = the sequence number itself.** This directly matches Kafka/EventStoreDB/AT
  Protocol's converged-upon approach, and is far simpler than the IRI-based or
  (timestamp,sequence)-tuple cursors considered and rejected earlier in this design process.
- Subscription request shape (transport-independent): `{stream: <id>, after: <seq> | null}`.
  `null` means "start from now" (live tail); full historical replay is a separate paginated
  bulk-read endpoint, not part of the live-subscribe path.
- **Gap handling**: if a requested `after` sequence number has aged out of the stream's
  retention window, the server returns an explicit gap signal (StreamLD's analog to Kafka's
  `OffsetOutOfRange`) rather than silently resuming from the wrong place. The client then falls
  back to the bulk/historical read path to catch up before re-subscribing live.

### 4.3 Transport bindings

Three bindings, two mandatory and one optional — mirroring CloudEvents' core-spec-plus-bindings
structure:

- **SSE (mandatory, server-to-client)**: browser-native reconnection via `Last-Event-ID`,
  which carries the sequence number directly. Requires HTTP/2 to avoid the classic
  6-connections-per-browser cap that plain HTTP/1.1 SSE hits.
- **WebSocket-based replication protocol (mandatory, server-to-server)** — the one genuinely
  novel piece of this standard. No existing prior art solves LDES-style (or any Linked-Data)
  server-to-server event replication; this fills that gap. Uses the same sequence-number cursor
  concept, carried as an explicit field per frame (no browser-native help here, so the
  reconnect-with-cursor handshake is defined explicitly in the spec).
- **MQTT (optional extension)**: real prior art exists for mapping topic hierarchies to RDF/IoT
  semantics (MQTT4SSN/MQTT2RDF), useful for IoT-sourced streams, but standard MQTT has no
  replay/resumption story, so it can't be a mandatory binding.

### 4.4 Spec document structure (CloudEvents-style)

Within `OpenFASTER-Standard/spec`'s `streamld/` directory:

- **Core spec**: the event envelope (sequence number, stream ID, RDF/JSON-LD payload, delta-vs
  -snapshot marker) — transport-independent.
- **Event format doc**: JSON-LD encoding (the only format for v1; room to add others later,
  as CloudEvents did with Avro/Protobuf/XML).
- **Protocol binding docs**, one per transport: SSE, WebSocket replication, MQTT (optional).
- **Subscription/discovery doc**: how a client discovers a stream and negotiates a cursor —
  kept separate from the transport bindings themselves, matching AsyncAPI's separation of
  Channel (discovery) from Operation (subscribe/publish direction) from Bindings (per-protocol).

## 5. Reference implementation (Riptide)

### 5.1 Stack

Elixir/Phoenix. The BEAM's actor model (lightweight processes + message passing) is an
event-driven core natively, not bolted on — a genuinely different starting point than Node.js's
single-threaded event loop or a from-scratch Rust actor framework. Phoenix PubSub/Channels give
real-time fan-out nearly for free.

### 5.2 Component breakdown

- **One GenServer per active stream** (per-resource actor, matching BEAM's actor-per-entity
  idiom) — owns sequence assignment for that stream, serializing writes without needing
  external distributed locking.
- **Phoenix PubSub** — internal fan-out from a stream's GenServer to all live subscribers
  (both SSE connections and WebSocket replication peers).
- **LDP HTTP surface** (Tier 1 scope, see §6) — resources, containers, CRUD, content
  negotiation (Turtle + JSON-LD), N3 Patch for partial updates. This is what makes Riptide a
  usable Solid pod server, not just an event log.

### 5.3 Data flow

- **Write path**: client `PUT`/`POST`/`PATCH`s an LDP resource → Riptide computes the RDF diff
  (`PATCH`) or full resource state (`PUT`/`POST`) → appends one StreamLD event to that
  resource's stream via its owning GenServer, which assigns the next sequence number → write is
  durable before the HTTP response returns.
- **Live subscribe path**: client opens an SSE connection (optionally with `Last-Event-ID`) or
  a peer server opens the WebSocket replication binding with an explicit cursor → the stream's
  GenServer tails new appends via Phoenix PubSub and pushes them in sequence order.
- **Bulk/historical path**: a plain paginated GET over the event log for "everything before
  now" — shares the underlying log with the live path but is a distinct read pattern, not part
  of live-subscribe.

### 5.4 Error handling

- **Gap on subscribe**: see §4.2 — explicit gap signal, client falls back to bulk read then
  re-subscribes from the new high-water mark.
- **Write conflicts**: naturally serialized by the per-stream GenServer; no external locking
  needed.
- **Disconnects**: SSE reconnects natively via the browser platform using `Last-Event-ID`; the
  WebSocket replication binding defines its own explicit reconnect-with-cursor handshake, since
  there's no platform-level help for that transport.

## 6. First-phase scope

Deliberately narrow, to isolate the genuinely novel bet (event-sourced storage + live
subscription) from well-understood engineering that can be layered on later without touching
the core:

- **In scope**: LDP resources + containers, GET/PUT/POST/DELETE/PATCH, Turtle + JSON-LD,
  StreamLD live subscription (SSE + WebSocket replication).
- **Out of scope (this phase)**: WebID-OIDC authentication, WAC/ACP access control, the MQTT
  binding, pod provisioning/multi-tenancy.

## 7. Open questions / future work

- Exact wire format details for the WebSocket replication binding (frame structure, handshake)
  — this is genuinely new design surface with no prior art to crib from, and needs its own
  focused design pass during spec authoring.
- A conformance test suite (CloudEvents ships one; StreamLD should too) so a future second
  implementation can be verified against Riptide rather than just against prose.
- When/whether to introduce an explicit maturity/status marker in OpenFASTER's own README to
  distinguish "incubating, domain-agnostic" standards like StreamLD from tightly-coupled
  domain modules like `mikadiv/`.
- Retention policy semantics (how long a stream keeps old sequence numbers before a subscriber
  hits the gap signal) — not yet designed, needed before the gap-handling behavior in §4.2 is
  fully specifiable.
