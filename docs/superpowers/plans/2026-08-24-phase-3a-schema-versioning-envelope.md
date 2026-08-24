# Phase 3a — Schema-Versioning Envelope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `Riptide.Event`/`Riptide.RDF.Patch` a versioned, explicit wire representation used at every point they cross into Ra's persistence layer, so a future struct-shape change can't silently corrupt reads of already-persisted data.

**Architecture:** `Event`/`Patch` each grow an `encode/1`/`decode/1` pair that converts to/from a version-tagged plain map (`%{v: 1, ...}`). `StreamServer.append/2` encodes before handing a command to Ra; `RaMachine.apply/3` decodes on the way in, stamps the sequence, then re-encodes before storing into `state.events` (so snapshots are wire-form too); `RaMachine.get_since/2` decodes back to structs before returning to callers. Public contracts of `StreamServer`/`RaMachine`'s query functions are unchanged.

**Tech Stack:** Elixir, `:ra` 2.15.4 (unchanged — no `:ra`-facing API used here), ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-24-phase-3a-schema-versioning-envelope-design.md`

## Global Constraints

- New functions are named `encode/1`/`decode/1` — NOT `to_wire`/`from_wire` (that name is already used by `Event.wire_snapshot?/1`/`Event.wire_payload/1` for the unrelated StreamLD wire protocol).
- Version key is `:v`, current version is `1`, wire format is a plain map (not a struct).
- Scope is `Riptide.Event` and `Riptide.RDF.Patch` only. Do not attempt to version `RDF.Graph`/`RDF.IRI`/`RDF.Term` (third-party `rdf_ex` types) — embed them as-is inside the wire map.
- No generic/reusable versioning behaviour or macro — this is Event/Patch-specific.
- No legacy-data decode fallback — there is no real persisted data yet, so `decode/1` only needs to understand versions this envelope itself introduces (starting at `v: 1`).
- `decode/1` raises on an unrecognized `v` rather than guessing.

---

### Task 1: `Riptide.RDF.Patch` encode/decode

**Files:**
- Modify: `lib/riptide/rdf/patch.ex`
- Test: `test/riptide/rdf/patch_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Patch.encode/1 :: Patch.t() -> map()`, `Patch.decode/1 :: map() -> Patch.t()`. Task 2 (`Event.encode/1`/`decode/1`) calls these directly for `:patch`-operation payloads.

- [ ] **Step 1: Write the failing round-trip test**

Add to `test/riptide/rdf/patch_test.exs` (keep the existing `@alice`/`@name` module attributes and tests as-is):

```elixir
  describe "encode/1 and decode/1" do
    test "round-trips a patch with both additions and removals" do
      patch = %Patch{
        additions: [{@alice, @name, RDF.literal("Alice")}],
        removals: [{@alice, @name, RDF.literal("Bob")}]
      }

      assert Patch.decode(Patch.encode(patch)) == patch
    end

    test "round-trips a patch with empty additions and removals" do
      patch = %Patch{additions: [], removals: []}

      assert Patch.decode(Patch.encode(patch)) == patch
    end

    test "encode/1 produces a version-tagged map" do
      patch = %Patch{additions: [], removals: []}

      assert Patch.encode(patch) == %{v: 1, additions: [], removals: []}
    end

    test "decode/1 raises a clear error on an unrecognized version" do
      assert_raise RuntimeError, ~r/Unknown Patch wire version: 99/, fn ->
        Patch.decode(%{v: 99, additions: [], removals: []})
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/rdf/patch_test.exs`
Expected: FAIL — `Patch.encode/1 is undefined or private`

- [ ] **Step 3: Implement `encode/1`/`decode/1`**

In `lib/riptide/rdf/patch.ex`, add after the existing `apply/2` function:

```elixir
  @spec encode(t()) :: map()
  def encode(%__MODULE__{additions: additions, removals: removals}) do
    %{v: 1, additions: additions, removals: removals}
  end

  @spec decode(map()) :: t()
  def decode(%{v: 1, additions: additions, removals: removals}) do
    %__MODULE__{additions: additions, removals: removals}
  end

  def decode(%{v: unknown}), do: raise("Unknown Patch wire version: #{inspect(unknown)}")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/rdf/patch_test.exs`
Expected: PASS (all tests in the file)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/rdf/patch.ex test/riptide/rdf/patch_test.exs
git commit -m "Add versioned encode/decode to Riptide.RDF.Patch"
```

---

### Task 2: `Riptide.Event` encode/decode

**Files:**
- Modify: `lib/riptide/event.ex`
- Test: `test/riptide/event_test.exs`

**Interfaces:**
- Consumes: `Patch.encode/1`, `Patch.decode/1` (Task 1) for `:patch`-operation payloads.
- Produces: `Event.encode/1 :: Event.t() -> map()`, `Event.decode/1 :: map() -> Event.t()`. Task 4 (`RaMachine`/`StreamServer`) calls these at the Ra persistence boundary.

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide/event_test.exs` (keep all existing tests as-is):

```elixir
  describe "encode/1 and decode/1" do
    test "round-trips a :replace event" do
      graph = RDF.Graph.new() |> RDF.Graph.add({RDF.iri("s"), RDF.iri("p"), RDF.iri("o")})
      event = Event.new("stream-1", :replace, graph)

      assert Event.decode(Event.encode(event)) == event
    end

    test "round-trips a :delete event" do
      event = Event.new("stream-1", :delete, RDF.Graph.new())

      assert Event.decode(Event.encode(event)) == event
    end

    test "round-trips a :patch event, including the nested Patch" do
      patch = %Patch{additions: [{RDF.iri("s"), RDF.iri("p"), RDF.iri("o")}], removals: []}
      event = Event.new("stream-1", :patch, patch)

      assert Event.decode(Event.encode(event)) == event
    end

    test "round-trips a stamped event's sequence number" do
      event = Event.new("stream-1", :replace, RDF.Graph.new()) |> Event.with_sequence(7)

      assert Event.decode(Event.encode(event)) == event
    end

    test "encode/1 produces a version-tagged map" do
      event = Event.new("stream-1", :replace, RDF.Graph.new())
      wire = Event.encode(event)

      assert wire.v == 1
      assert wire.operation == :replace
      assert wire.stream_id == "stream-1"
    end

    test "decode/1 raises a clear error on an unrecognized version" do
      assert_raise RuntimeError, ~r/Unknown Event wire version: 99/, fn ->
        Event.decode(%{v: 99, sequence: nil, stream_id: "s", operation: :replace, payload: RDF.Graph.new()})
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/event_test.exs`
Expected: FAIL — `Event.encode/1 is undefined or private`

- [ ] **Step 3: Implement `encode/1`/`decode/1`**

In `lib/riptide/event.ex`, add after `with_sequence/2` (before `wire_snapshot?/1`):

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

  def decode(%{v: unknown}), do: raise("Unknown Event wire version: #{inspect(unknown)}")

  defp decode_payload(:patch, payload), do: Patch.decode(payload)
  defp decode_payload(_operation, payload), do: payload
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/event_test.exs`
Expected: PASS (all tests in the file)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/event.ex test/riptide/event_test.exs
git commit -m "Add versioned encode/decode to Riptide.Event"
```

---

### Task 3: Prove the upcast-chain pattern with a synthetic two-version example

**Why this task exists:** `Event`/`Patch` only have one real version today, so nothing in Task 1/2 exercises the "decode an old version, upcast it forward, recurse" chain the design spec (§5) commits to for future version bumps. This task builds a small, throwaway two-version example (not used by any production code) purely to prove that pattern actually works mechanically before we rely on it later.

**Files:**
- Create: `test/support/versioned_example.ex`
- Create: `test/riptide/versioned_upcast_test.exs`

**Interfaces:**
- Consumes: nothing from Task 1/2 — fully independent, synthetic example.
- Produces: nothing consumed elsewhere — this task's deliverable is the passing test itself, as evidence the pattern works.

- [ ] **Step 1: Write the synthetic two-version module**

Create `test/support/versioned_example.ex`:

```elixir
defmodule Riptide.Test.VersionedExample do
  @moduledoc """
  A minimal, throwaway two-version encode/decode chain. Exists only to prove
  the upcast-then-recurse `decode/1` pattern described in the Phase 3a design
  spec (§5) works mechanically — `Riptide.Event`/`Riptide.RDF.Patch` only have
  one real version today and can't demonstrate an actual version bump yet.
  Not used by any production code.
  """

  defstruct [:name, :count]

  @type t :: %__MODULE__{name: String.t(), count: non_neg_integer()}

  @spec decode(map()) :: t()
  def decode(%{v: 2, name: name, count: count}) do
    %__MODULE__{name: name, count: count}
  end

  def decode(%{v: 1} = wire) do
    wire |> upcast_v1_to_v2() |> decode()
  end

  # v1 had no `count` field; v2 added it, defaulting absent counts to 0.
  defp upcast_v1_to_v2(%{v: 1, name: name}) do
    %{v: 2, name: name, count: 0}
  end
end
```

- [ ] **Step 2: Write the failing tests**

Create `test/riptide/versioned_upcast_test.exs`:

```elixir
defmodule Riptide.VersionedUpcastTest do
  use ExUnit.Case, async: true

  alias Riptide.Test.VersionedExample

  test "decode/1 upcasts an old-version map through to the current shape" do
    old_wire = %{v: 1, name: "alice"}

    assert VersionedExample.decode(old_wire) == %VersionedExample{name: "alice", count: 0}
  end

  test "decode/1 decodes the current version directly, without upcasting" do
    current_wire = %{v: 2, name: "bob", count: 5}

    assert VersionedExample.decode(current_wire) == %VersionedExample{name: "bob", count: 5}
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/riptide/versioned_upcast_test.exs`
Expected: FAIL — `Riptide.Test.VersionedExample.decode/1 is undefined` (module not yet compiled/found, since Step 1's file was just added — if it fails to compile instead, that also counts as the expected "not yet working" state; the point is confirming the test doesn't pass trivially before Step 1 logic is exercised in Step 4)

Note: since Step 1 and Step 2 are both being added new (there's no pre-existing broken implementation to test against here, unlike Tasks 1/2), this step's purpose is a compile/sanity check rather than a true red-then-green cycle — confirm the test file and support module both compile and the assertions actually run.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/versioned_upcast_test.exs`
Expected: PASS (both tests)

- [ ] **Step 5: Commit**

```bash
git add test/support/versioned_example.ex test/riptide/versioned_upcast_test.exs
git commit -m "Add synthetic test proving the version-upcast decode pattern"
```

---

### Task 4: Wire encode/decode into the Ra persistence boundary

**Files:**
- Modify: `lib/riptide/stream/ra_machine.ex`
- Modify: `lib/riptide/stream/stream_server.ex`
- Modify: `test/riptide/stream/ra_machine_test.exs`
- Modify: `test/riptide/ra_cluster_test.exs`

**Interfaces:**
- Consumes: `Event.encode/1`, `Event.decode/1` (Task 2).
- Produces: no new public interface — `StreamServer.append/2`'s and `RaMachine.get_since/2`'s existing public contracts (`Event.t()` in, `{:ok, [Event.t()]} | {:gap, ...}` out) are preserved; `RaMachine.state()`'s `events` field now holds wire maps instead of `Event.t()` structs (internal to `RaMachine`, not part of any public contract).

- [ ] **Step 1: Write the failing tests — update the two tests that construct raw `{:append, %Event{}}` commands directly**

These two tests currently bypass `StreamServer.append/2` and hand a raw `%Event{}` struct straight to Ra/`RaMachine`. Once Step 3 below changes `RaMachine.apply/3` to expect an encoded wire map, both need to encode first.

In `test/riptide/stream/ra_machine_test.exs`, replace the `append/3` helper:

```elixir
  defp append(state, stream_id, index \\ 1) do
    {new_state, event, _effects} =
      RaMachine.apply(
        %{index: index},
        {:append, Event.encode(Event.new(stream_id, :replace, RDF.Graph.new()))},
        state
      )

    {new_state, event}
  end
```

In `test/riptide/ra_cluster_test.exs`, in the `"Ra truncates its on-disk log once retention trimming releases a cursor"` test, replace the `for` loop body (around line 76-79):

```elixir
    for _ <- 1..50 do
      {:ok, %Event{}, _leader} =
        :ra.process_command(
          server_id,
          {:append, Event.encode(Event.new(stream_id, :replace, RDF.Graph.new()))}
        )
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/stream/ra_machine_test.exs test/riptide/ra_cluster_test.exs`
Expected: FAIL — `RaMachine.apply/3` still expects `{:append, %Event{}}` (a raw struct won't match the new `Event.decode/1`-based clause once Step 3 lands) or, before Step 3 lands, these edited tests still pass trivially against the *old* `apply/3` (which pattern-matches `%Event{}` directly and would now receive an encoded map instead, which does NOT match `%Event{} = event`) — confirm the failure is real: run this *before* Step 3, expect a `FunctionClauseError` in `RaMachine.apply/3`.

- [ ] **Step 3: Update `RaMachine.apply/3` and `RaMachine.get_since/2`**

In `lib/riptide/stream/ra_machine.ex`, replace the `apply/3` clause:

```elixir
  @impl :ra_machine
  def apply(meta, {:append, wire}, state) do
    event = Event.decode(wire)
    stamped = Event.with_sequence(event, state.next_sequence)
    stamped_wire = Event.encode(stamped)
    {events, trimmed?} = trim(state.events ++ [stamped_wire], state.retention)
    new_state = %{state | next_sequence: state.next_sequence + 1, events: events}
    {new_state, stamped, release_cursor_effects(trimmed?, meta, new_state)}
  end
```

Update the `state()` type (`events` now holds wire maps, not structs) and add a short note on why, right above the type:

```elixir
  # `events` holds each event's *encoded* wire-form map (see `Riptide.Event.encode/1`),
  # not a raw `%Event{}` struct — this is what actually gets persisted (both in Ra's
  # command log and in machine-state snapshots), so it must stay in the versioned
  # format regardless of whether this stream's Ra cluster ever triggers a snapshot.
  # See Phase 3a design spec, §4.
  @type state :: %{
          next_sequence: pos_integer(),
          events: [map()],
          retention: :infinity | pos_integer()
        }
```

Replace `get_since/2`'s final clause to decode before returning:

```elixir
  def get_since(state, cursor) do
    oldest = List.first(state.events) |> then(&(&1 && &1.sequence))

    if oldest != nil and cursor < oldest - 1 do
      {:gap, oldest}
    else
      {:ok, state.events |> Enum.filter(&(&1.sequence > cursor)) |> Enum.map(&Event.decode/1)}
    end
  end
```

`trim/2` and `release_cursor_effects/2` need no changes — both are agnostic to whether `events` holds structs or wire maps.

- [ ] **Step 4: Update `StreamServer.append/2` to encode before sending the command**

In `lib/riptide/stream/stream_server.ex`, replace `append/2`'s body:

```elixir
  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    server_id = RaCluster.server_id(stream_id)
    stamped = RaCluster.process_command(server_id, {:append, Event.encode(event)})
    Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> stream_id, {:new_event, stamped})
    stamped
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide/stream/ra_machine_test.exs test/riptide/ra_cluster_test.exs test/riptide/stream/stream_server_test.exs`
Expected: PASS (all tests in all three files)

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/stream/ra_machine.ex lib/riptide/stream/stream_server.ex \
        test/riptide/stream/ra_machine_test.exs test/riptide/ra_cluster_test.exs
git commit -m "Route Event persistence through the versioned encode/decode boundary"
```

---

### Task 5: Full verification + PROGRESS.md + wrap-up

**Files:**
- Modify: `PROGRESS.md`
- No new source files.

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing further downstream — this is the terminal task.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — in particular, confirm the pre-existing issue #6 regression test (`test/riptide/ra_cluster_cold_restart_test.exs`) and the issue #8 100-trial test (`test/riptide/stream/stream_server_test.exs`, `"get_since/2 never observes a stale/incomplete state immediately after a restart (issue #8)"`) still pass — these are real evidence the new encode/decode boundary doesn't reintroduce either bug, not just that the new tests pass in isolation.

- [ ] **Step 2: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean (0 issues / no diff). Fix anything flagged and re-run.

- [ ] **Step 3: Update `PROGRESS.md`**

In the `## 3. Clustering / horizontal scale / HA — decomposed into phases` section, change the Phase 3a bullet's trailing `**Not yet designed.**` to:

```markdown
  Fully self-contained — doesn't depend on anything else in this sub-project. **Shipped
  2026-08-24** — see `docs/superpowers/specs/2026-08-24-phase-3a-schema-versioning-envelope-design.md`.
```

Change the `**Status**:` line at the end of that section from:

```markdown
**Status**: phasing agreed with the operator; Phase 3a's own brainstorm/design has not started yet.
```

to:

```markdown
**Status**: Phase 3a shipped. Phase 3b (real multi-node connectivity) not yet started.
```

- [ ] **Step 4: Commit**

```bash
git add PROGRESS.md
git commit -m "Mark Phase 3a shipped in PROGRESS.md"
```

- [ ] **Step 5: Push and open a PR**

```bash
git push -u origin <branch-name>
gh pr create --title "Phase 3a: schema-versioning envelope for Event/Patch" --body "$(cat <<'EOF'
## Summary
- Implements the Phase 3a design spec (docs/superpowers/specs/2026-08-24-phase-3a-schema-versioning-envelope-design.md).
- Riptide.Event/Riptide.RDF.Patch gain versioned encode/1 and decode/1. StreamServer.append/2 encodes before writing to Ra; RaMachine.apply/3 decodes on the way in and re-encodes into state (so snapshots stay versioned too); RaMachine.get_since/2 decodes back to structs before returning. Public contracts unchanged.
- A synthetic two-version example (test/support/versioned_example.ex) proves the upcast-then-recurse decode pattern works mechanically, since Event/Patch only have one real version so far.

## Test plan
- [x] mix test — full suite passes, including the pre-existing issue #6 and issue #8 regression tests
- [x] mix credo --strict
- [x] mix format --check-formatted
EOF
)"
```

Report the PR URL and stop — do not merge without explicit human sign-off (ask via AskUserQuestion), matching this project's established practice for every prior PR this session.
