# Riptide

Riptide is the reference implementation of **StreamLD**, a clean-slate, professional-grade
standard for real-time-capable Linked Data event streaming — incubating within the
[OpenFASTER](https://openfaster.org) ecosystem.

Riptide is an Elixir/Phoenix server that speaks enough Solid/LDP to act as a usable pod
server, backed natively by a StreamLD event log instead of a request/response pipeline —
an event-driven alternative to [Community Solid Server](https://github.com/CommunitySolidServer/CommunitySolidServer).

Design status: implemented and tested (unit + controller/channel tests passing). See
`docs/superpowers/specs/2026-08-22-streamld-riptide-design.md` for the full design and its
rationale.

The StreamLD specification itself lives in a separate repo:
[`OpenFASTER-Standard/spec`](https://github.com/OpenFASTER-Standard/spec).

## How the pieces fit together

At the core of Riptide is a per-stream, sequence-numbered event log:
`Riptide.Stream.StreamServer` is a thin client (no GenServer of its own) over a single-node
`Ra`-replicated (Raft) cluster, one per stream, dynamically started/restarted on demand via
`Riptide.RaCluster` — the only module that talks to `:ra` directly. Each stream's log is a
`Riptide.Stream.RaMachine`, a pure `:ra_machine` that assigns each appended event the next
sequence number and applies retention trimming, with events committed durably to disk through
Ra's write-ahead log instead of living only in process memory, so a stream survives a crash or
restart with its data and sequence numbers intact. Every append also broadcasts the new event
over `Phoenix.PubSub` on the `"stream:<stream_id>"` topic — this is the internal fan-out
mechanism that both realtime surfaces below subscribe to, decoupling the write path from however
many readers are currently attached.

Riptide exposes that event log through three HTTP/WS surfaces:

- **LDP CRUD** (`RiptideWeb.LDP.ResourceController`) — `GET`/`PUT`/`PATCH`/`DELETE`/`POST` on
  `/resources/*path`. `GET` folds a stream's events into its current RDF graph; `PUT`/`DELETE`
  append snapshot events; `PATCH` appends a delta event from a JSON body's `additions`/
  `removals` Turtle fields; `POST` to a container path creates a child resource and records an
  `ldp:contains` triple back on the container.
- **SSE subscription** (`RiptideWeb.Realtime.SseController`) — `GET
  /streams/:stream_id/subscribe`, with `Last-Event-ID` support for resuming a dropped
  connection. Replies with a backlog of events since the given cursor, then streams further
  `Phoenix.PubSub` broadcasts as they arrive; if the requested cursor has already fallen out of
  the stream's retention window, responds `409` with `{"oldestAvailable": <seq>}` instead.
- **WebSocket replication** (`RiptideWeb.Realtime.ReplicationChannel`) — joins the
  `replication:<stream_id>` topic on the `/replication` socket with an `"after"` cursor,
  analogous to the SSE endpoint but over Phoenix Channels: join replies with a backlog, and
  subsequent events are pushed as `"replication_frame"` messages. A cursor outside the
  retention window is rejected at join time with `{"oldestAvailable": <seq>}`, matching the SSE
  gap-signal shape.
