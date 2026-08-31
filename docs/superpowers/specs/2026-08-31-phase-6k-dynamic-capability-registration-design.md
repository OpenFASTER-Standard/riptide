# Phase 6k — Dynamic Capability Registration

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. This phase implements
**6k — dynamic Capability registration**, the concrete consumer 6j's own spec named as motivating but
explicitly out of scope: `Riptide.Capability.invoke/4` shells out to `wasmtime` against a literal
local filesystem path (`Definition.component`), and `Riptide.Derivation.ExecuteInterpreter.Context`
has no catalog of its own — every caller must hand-build its `capabilities`/`rules` maps today
(confirmed directly in `Context`'s own moduledoc: "no Capability/Rule catalog exists yet").

This phase closes the Capability half of that gap: a real, reviewed, Hub-scope catalog of
Capabilities, addressable by IRI, with their WASM bytes durably stored via 6j's `BlobStore` and
materialized to a literal local path only at the moment a specific node actually invokes one. Wiring
this catalog into `ExecuteInterpreter.Context` resolution, and reactively triggering invocation from
a Fact write, is **6l**, a separate, dependent phase — this phase stands alone and is independently
testable: a Capability can be registered, reviewed, and invoked by IRI with zero Task/trigger
machinery.

## 2. Scope

- A `CapabilityCatalogEntry` data shape — the same fields `Capability.Definition` already has
  (`name`, `kind`, `function`, `fuel_limit`, `timeout_ms`, `memory_limits`), except `component`
  (a literal path) is replaced by `component_hash` (a `BlobStore` content hash) — see §4.
- `Riptide.Derivation.CapabilityCatalog.materialize/1`: resolves a `CapabilityCatalogEntry` into a
  real, invokable `Capability.Definition.t()` by ensuring its WASM bytes exist on the invoking node's
  local disk, reusing a local `BlobStore` replica if one already exists (§5).
- A review pipeline for admitting a new Capability into the Hub catalog, mirroring 6i's
  `PendingCrosswalkReview` shape exactly — propose, human approve/decline, no anti-unification or
  fidelity-replay (§6).
- A dedicated HTTP endpoint, `POST /tenants/:tenant_id/hub/capabilities`, that accepts both the
  Definition metadata and the WASM bytes in one request, storing the bytes via `BlobStore.put/1`
  internally — without giving `BlobStore` itself a general-purpose upload endpoint (§7).

## 3. Out of scope

- Wiring `ExecuteInterpreter.Context` to resolve from this catalog, or anything about reactive
  execution triggering. That is entirely **6l**'s scope; this phase only makes registered Capabilities
  *resolvable and materializable* by IRI via a plain library call.
- Per-tenant "Install" of Capabilities (mirroring 6i's Rule-install flow). A `CapabilityCatalogEntry`
  has no `FactPattern` predicates to rewrite per tenant vocabulary — nothing in it is
  tenant-vocabulary-dependent — so there is no rewriting concern an Install step would exist to solve.
  Once approved, any tenant already-authorized (via the existing, unchanged `["capabilities",
  local_name]` ACP path) may invoke it directly; there is no per-tenant copy to make.
- Revoking/un-admitting a live Capability, or versioning (registering a second Definition under the
  same name). Both are real operational needs but orthogonal to this phase's own exit criterion —
  left for later work, same as 6h-i explicitly deferred several operational concerns.
- Any change to `Riptide.Capability`, `Capability.Definition`, or `invoke/4` themselves. This phase
  is purely additive: `materialize/1` produces an ordinary `Definition.t()` that flows into the
  *unmodified* `invoke/4`, unchanged since 6b-i.
- GC of the local materialization cache (§5) — deferred, mirroring `BlobStore`'s own deferred-GC
  precedent (6j §8).

## 4. Data model

```elixir
defmodule Riptide.Derivation.CapabilityCatalogEntry do
  @moduledoc """
  A Hub-scope, reviewed Capability, addressable by IRI. Identical field set to
  `Riptide.Capability.Definition` except `component` (a literal local path,
  meaningless outside the node that happened to receive it) is replaced by
  `component_hash` (a content hash, resolvable to real bytes on any node via
  `Riptide.BlobStore` — see `CapabilityCatalog.materialize/1`).
  """

  @enforce_keys [:name, :kind, :component_hash, :function, :fuel_limit, :timeout_ms, :memory_limits]
  defstruct [:name, :kind, :component_hash, :function, :fuel_limit, :timeout_ms, :memory_limits]

  @type t :: %__MODULE__{
          name: RDF.IRI.t(),
          kind: :effect | :observe,
          component_hash: String.t(),
          function: String.t(),
          fuel_limit: pos_integer(),
          timeout_ms: pos_integer(),
          memory_limits: Riptide.Capability.Definition.memory_limits()
        }
end
```

Storage mirrors Crosswalk's exact precedent (6i §6): a sibling stream off the existing Hub catalog,
`Catalog.catalog_stream_id(:hub) <> "/capabilities"`, with `Catalog.admit_capability/1`/
`list_capabilities/0` (no `scope` param — always `:hub`, same reasoning as Crosswalk: this is
inherently shared, non-tenant-vocabulary-dependent content). A new `CapabilityCatalogRDFCodec`
(`to_rdf/1`/`from_rdf/2`) follows the exact reification style `RuleRDFCodec`/`CrosswalkRDFCodec`
already established — explicit case-based encode/decode for the `kind` atom (`:effect`/`:observe`),
not `Atom.to_string/1`/`String.to_existing_atom/1` against atoms absent from `lib/`'s own literals,
per the exact bug 6i already found and fixed once for `CrosswalkRDFCodec`'s `match_type`. New vocab
terms: `urn:riptide:vocab:CapabilityCatalogEntry`, `urn:riptide:vocab:componentHash`,
`urn:riptide:vocab:capabilityKind`, `urn:riptide:vocab:capabilityFunction`,
`urn:riptide:vocab:fuelLimit`, `urn:riptide:vocab:timeoutMs`, plus the four `memory_limits` fields —
following the existing `urn:riptide:vocab:<camelCase>` property convention exactly.

## 5. Materialization

```elixir
@spec materialize(CapabilityCatalogEntry.t()) :: {:ok, Capability.Definition.t()} | {:error, term()}
def materialize(%CapabilityCatalogEntry{} = entry) do
  with {:ok, path} <- ensure_local(entry.component_hash) do
    {:ok,
     %Capability.Definition{
       name: entry.name,
       kind: entry.kind,
       component: path,
       function: entry.function,
       fuel_limit: entry.fuel_limit,
       timeout_ms: entry.timeout_ms,
       memory_limits: entry.memory_limits
     }}
  end
end
```

`ensure_local/1` checks `File.exists?(BlobStore.path_for(hash))` first — if this node already holds a
replica (it's one of the RF nodes `BlobStore.put/1` originally replicated to, or a past materialize
call already fetched it), reuse that path directly, zero extra copy. Otherwise, `BlobStore.get/1`
fetches the verified bytes over the network and writes them into a **separate, private** cache
directory (`RIPTIDE_CAPABILITY_CACHE_DIR`, default `priv/capability_cache/<hash>`) — deliberately
*not* registered with `BlobStore`'s own `LocationIndex` (6j §7), since this is a local
invoke-optimization cache, not an official replica other nodes should be routed to for `get/1`. GC of
this cache is out of scope (§3), mirroring `BlobStore`'s own deferred-GC precedent.

## 6. Review pipeline

Mirrors `DedupGate.propose_crosswalk/2`/`approve_crosswalk_review/2`/`decline_crosswalk_review/2` and
`PendingCrosswalkReview`'s exact simpler shape (6i §6, `dedup_gate.ex:153-194`) — no
Reject/Merge/Admit classification, no fidelity evidence, since a `CapabilityCatalogEntry` isn't a
generalization of anything (there's nothing to anti-unify or replay-test the way a Rule's
`CapabilityReference` literals are).

```elixir
defmodule Riptide.Derivation.DedupGate.PendingCapabilityReview do
  @enforce_keys [:candidate]
  defstruct [:candidate]
  @type t :: %__MODULE__{candidate: CapabilityCatalogEntry.t()}
end

@spec propose_capability(Catalog.scope(), CapabilityCatalogEntry.t()) ::
        {:ok, RDF.BlankNode.t()} | {:error, term()}
def propose_capability(scope, entry)

@spec approve_capability_review(Catalog.scope(), RDF.BlankNode.t()) :: :ok | {:error, term()}
def approve_capability_review(scope, node)

@spec decline_capability_review(Catalog.scope(), RDF.BlankNode.t()) :: :ok | {:error, term()}
def decline_capability_review(scope, node)
```

`scope` here is the *proposing* tenant's own pending-review stream (matching `propose_crosswalk/2`'s
exact pattern) — approval always admits into the Hub capability stream (§4), never a tenant-scoped
one, since Capabilities have no per-tenant variant (§3).

## 7. HTTP surface

A new `RiptideWeb.Hub.CapabilityController`, same pipeline and JSON response conventions as
`InstallController`/`CrosswalkController` (`[:api, :tenant, :auth, :authz]`, bare 200/404/503 for
approve/decline, `{"outcome": "queued"/"rejected", "node_id": ..., "reason": ...}` for propose):

| Method | Path | Operation |
|---|---|---|
| POST | `/tenants/:tenant_id/hub/capabilities` | Store bytes via `BlobStore.put/1`, build a `CapabilityCatalogEntry`, `propose_capability/2` |
| POST | `/tenants/:tenant_id/hub/capability-reviews/:node_id/approve` | `approve_capability_review/2` |
| POST | `/tenants/:tenant_id/hub/capability-reviews/:node_id/decline` | `decline_capability_review/2` |

The propose request body carries both the Definition metadata (JSON) and the WASM bytes
(multipart or base64-encoded field — implementation detail, not a design decision) in a single
request; the controller calls `BlobStore.put/1` on the decoded bytes to obtain `component_hash`
before constructing the `CapabilityCatalogEntry` it proposes. This gives registration a real,
self-service interface without reopening 6j's own explicitly-stated scope: `BlobStore` itself still
has no general-purpose upload endpoint (6j §3) — only this one Capability-specific endpoint, whose
own privileged/reviewed nature already requires the same trust `BlobStore.put/1` assumes of any
caller (6j §9).

## 8. Security boundary

Catalog admission ("this Capability is vetted, trusted to run arbitrary WASI code on the fleet") and
invoke authorization ("this tenant/subject may invoke it") stay the cleanly separate concerns they
already are: `PendingCapabilityReview` approval is the *admission* gate (§6); the existing, unchanged
`Riptide.Capability.authorized?/3` (`["capabilities", local_name]` ACP path, per-tenant policy) is the
*invocation* gate. Approving a Capability into the Hub catalog does not itself authorize anyone to
invoke it — a tenant still needs its own `Policy` granting `:invoke`, exactly as today for any
caller-supplied Capability.

## 9. Testing

- `CapabilityCatalogRDFCodec` round-trip, including the explicit `kind` atom encode/decode (not
  `String.to_existing_atom/1`).
- `materialize/1`'s two paths: reusing an already-local `BlobStore` replica (zero network fetch,
  verified via a mock/counter), and fetching-and-caching from a remote replica on a node with no
  local copy — real multi-node test, mirroring 6j's own `:peer`-based convention.
- Review pipeline: propose → approve admits into the live Hub capability stream; propose → decline
  resolves without admitting; declining an already-resolved node is rejected.
- HTTP: `CapabilityController` propose/approve/decline against the real pipeline, mirroring
  `InstallControllerTest`'s/`CrosswalkControllerTest`'s own shape.
- **Capstone, proving the exit criterion literally**: register a Capability through the real HTTP
  endpoint (bytes + metadata in one request), approve it, then resolve and invoke it *by IRI* through
  `CapabilityCatalog.list_capabilities/0` + `materialize/1` + the unmodified `Capability.invoke/4` —
  no caller-supplied `Definition` anywhere in the call path. This is the first invocation in the
  codebase that never touches a hand-built `%Definition{}`.

## 10. Exit criterion

A Capability can be registered (bytes + metadata) through a real HTTP endpoint, reviewed and approved
into a Hub-scope catalog, and subsequently resolved and invoked by IRI alone — its WASM bytes
materialized to a literal local path on whichever node performs the invocation, transparently, via
`BlobStore` — with zero changes to `Riptide.Capability`/`Definition`/`invoke/4` themselves.
