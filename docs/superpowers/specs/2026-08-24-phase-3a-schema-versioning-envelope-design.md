# Phase 3a — Schema-Versioning Envelope — Design

**Status:** Approved 2026-08-24.

Sub-project 3 (Clustering / horizontal scale / HA) is decomposed into four phases (see
`PROGRESS.md`, § "3. Clustering / horizontal scale / HA"). This is Phase 3a: a versioned wrapper
around persisted `Riptide.Event`/`Riptide.RDF.Patch` terms so a future struct-shape change doesn't
break reading old data. Pulled forward from a someday-risk (deferred in sub-project 1's design
doc §6) to a live one, because multi-node rolling deploys (Phase 3b+) mean nodes can briefly run
different code versions against the same persisted data mid-deploy. Fully self-contained — doesn't
depend on anything else in this sub-project.

## 1. Context and motivation

Riptide's only durable storage is `:ra`'s own WAL/segment/snapshot files, and `:ra` serializes
whatever Erlang term it's handed using plain `:erlang.term_to_binary`/`binary_to_term` (confirmed
by reading the vendored `:ra` 2.15.4 source: `ra_log_wal.erl:994-995` for the WAL write path,
`ra_log_wal.erl:851,863,894,917` for WAL read/recovery, `ra_log_snapshot.erl:51-52,246-247` for
snapshot write/read). There is no serialization hook a `:ra_machine` can customize, and `:ra`'s own
"machine version" concept (`ra_machine.erl`'s optional `version/0`/`which_module/1` callbacks) is
about which module's `apply/3` *logic* runs for a given log index — it does not version the *data
format*, and provides no migration/upcast hook (`grep -rn "upgrade\|migrat" deps/ra/src/*.erl`
returns zero hits).

Empirically verified (live experiment: encode a struct under one `defstruct` shape, decode it
under a module recompiled with a different shape): decoding an old-shaped term under a changed
`defstruct` **succeeds silently** — it returns the *old* field set with the current module's
`__struct__` tag attached, not an error. Stale fields stay silently readable forever; a field added
after the data was written raises `KeyError` only on first access, not at decode time. Nothing
about `:ra` or raw Erlang term encoding would catch a struct-shape drift before it caused a
production bug.

Separately, `RaMachine`'s own `release_cursor_effects/2` only fires when a trimming append happens
(bounded-retention streams). Streams with `:infinity` retention (`StreamServer.start_link/2`'s
default) never trim, so **never snapshot** — meaning their entire history lives forever as raw WAL
*command* entries, replayed via `apply/3` from index 0 on every restart, never refreshed through a
snapshot rewrite. This is the binding constraint on where this fix has to live: it isn't enough to
version the machine's in-memory `state`, since state alone is only ever re-persisted for streams
that actually snapshot. The fix has to control the actual term handed to `:ra.process_command/2` at
write time.

## 2. Scope

- Covers `Riptide.Event` and `Riptide.RDF.Patch` only — Riptide's own structs. Explicitly does
  *not* attempt to version the third-party `rdf_ex` types embedded inside them (`RDF.Graph.t()`
  payloads, `RDF.IRI.t()`/`RDF.Term.t()` triples inside `Patch`) — `rdf_ex` is pinned to an exact
  version in `mix.lock`, so a version bump is a deliberate, reviewed action, not something that
  happens silently underneath a running cluster.
- Built specifically for `Event`/`Patch` — not a generic `Riptide.Versioned`-style behaviour/macro.
  No second struct is known to need this yet; a shared abstraction would be designed against
  guesses rather than a second real use case.
- No legacy-data fallback: Riptide is early-stage with no real persisted stream data in any
  environment today, so the new versioned format can simply be "version 1," with no need to also
  decode today's raw, untagged struct shape.

## 3. Wire format & naming

`Riptide.Event` already defines `wire_snapshot?/1` and `wire_payload/1`, which map an `Event` to
the *StreamLD* wire protocol (the external HTTP/SSE format) — an unrelated concept to Ra's on-disk
persistence format. To avoid colliding with that existing meaning, the new functions are named
`encode/1`/`decode/1`, not `to_wire`/`from_wire`.

`Riptide.RDF.Patch`:

```elixir
@spec encode(t()) :: map()
def encode(%__MODULE__{additions: additions, removals: removals}) do
  %{v: 1, additions: additions, removals: removals}
end

@spec decode(map()) :: t()
def decode(%{v: 1, additions: additions, removals: removals}) do
  %__MODULE__{additions: additions, removals: removals}
end
```

`Riptide.Event`:

```elixir
@spec encode(t()) :: map()
def encode(%__MODULE__{} = event) do
  %{
    v: 1,
    sequence: event.sequence,
    stream_id: event.stream_id,
    operation: event.operation,
    payload: encode_payload(event.operation, event.payload)
  }
end

defp encode_payload(:patch, %Patch{} = payload), do: Patch.encode(payload)
defp encode_payload(_operation, payload), do: payload

@spec decode(map()) :: t()
def decode(%{v: 1} = wire) do
  %__MODULE__{
    sequence: wire.sequence,
    stream_id: wire.stream_id,
    operation: wire.operation,
    payload: decode_payload(wire.operation, wire.payload)
  }
end

defp decode_payload(:patch, payload), do: Patch.decode(payload)
defp decode_payload(_operation, payload), do: payload
```

(Exact private-helper shape confirmed/adjusted during implementation; the public `encode/1`/
`decode/1` contract above is fixed.)

## 4. Data flow

Encode happens at exactly one place: `StreamServer.append/2` calls `Event.encode(event)` before
calling `RaCluster.process_command(server_id, {:append, encoded})` — so the term `:ra` actually
writes to the WAL is always the versioned map, never the raw struct.

`RaMachine.apply/3` decodes it (`Event.decode/1`) to work with a real struct, stamps the sequence
exactly as today, then **re-encodes** the stamped event before appending it to `state.events` — so
`state` (and therefore any snapshot `:ra` ever takes of it) holds wire-form maps too, closing the
gap identified in §1 for streams that do snapshot, not just the common `:infinity`-retention case.
`apply/3`'s *reply* value (returned to the caller, never persisted) stays a real decoded `%Event{}`
struct, so `StreamServer.append/2`'s public return type is unchanged.

`get_since/2` decodes each wire map back to a struct right before returning, so its public contract
(`{:ok, [Event.t()]}`) is unchanged. `trim/2` and the `oldest`-sequence lookup in `get_since/2`
need no changes — both only touch `.sequence`, a plain top-level key on the wire map exactly as it
is on the struct.

```elixir
# RaMachine.apply/3, current shape (for reference — full diff during implementation):
def apply(meta, {:append, wire}, state) do
  event = Event.decode(wire)
  stamped = Event.with_sequence(event, state.next_sequence)
  stamped_wire = Event.encode(stamped)
  {events, trimmed?} = trim(state.events ++ [stamped_wire], state.retention)
  new_state = %{state | next_sequence: state.next_sequence + 1, events: events}
  {new_state, stamped, release_cursor_effects(trimmed?, meta, new_state)}
end
```

`RaCluster.process_command/2` itself needs no changes — it already accepts arbitrary command
terms, agnostic to what they mean.

## 5. Version bumps & unknown versions

`decode/1` is a multi-clause function, one clause per known version; only the *current* version's
clause builds the struct directly. When a future version 2 is introduced, today's
`decode(%{v: 1} = wire)` clause changes from "build directly" to "upcast `wire` to v2 shape, then
recurse into `decode/1`" — e.g.:

```elixir
def decode(%{v: 2} = wire), do: build_from_v2(wire)
def decode(%{v: 1} = wire), do: wire |> upcast_v1_to_v2() |> decode()
```

so each version's decode logic only ever needs to know the immediately-prior version's shape, not
the full history. `encode/1` always emits the current version.

If `decode/1` receives a `v` it doesn't recognize (e.g. a node reading data written by a newer
Riptide version mid-rolling-deploy — not reachable yet from Phase 3a alone, since single-node
deploys can't observe this, but exactly the risk Phase 3b/3c's multi-node rollouts will introduce),
it raises loudly rather than guessing:

```elixir
def decode(%{v: unknown}), do: raise "Unknown Event wire version: #{inspect(unknown)}"
```

Silently misinterpreting an unrecognized future format would be worse than a hard, visible failure.

## 6. Testing

- **Round-trip tests**: `Event.decode(Event.encode(event)) == event` across all three operations
  (`:replace`, `:delete`, `:patch`), and the same for `Patch`.
- **Upcast-machinery test**: since there's no real historical version to test against yet, a
  synthetic fabricated old-version shape (clearly marked as synthetic in the test) proves the
  upcast-then-recurse chain itself works mechanically — not just that today's single-version case
  round-trips.
- **Existing end-to-end regression tests** (`ra_cluster_cold_restart_test.exs` for issue #6,
  `stream_server_test.exs`'s 100-trial issue #8 test) run unchanged and now exercise the new
  encode/decode boundary through real Ra persistence, not just in isolation — real evidence this
  doesn't reintroduce either bug.
- Any existing `RaMachine`/`Event`/`Patch` unit test asserting on `state.events`' shape directly
  (now wire maps, not structs) gets updated accordingly.

## 7. Out of scope

- Versioning `rdf_ex` types (`RDF.Graph`, `RDF.IRI`, `RDF.Term`) — see §2.
- A generic/reusable versioning mechanism for structs beyond `Event`/`Patch` — see §2.
- Decoding today's pre-3a raw, untagged struct data — see §2 (no real persisted data exists yet).
- Phases 3b–3d (multi-node connectivity, sharded placement, HA proof) — separate specs, in
  sequence, per `PROGRESS.md`.
