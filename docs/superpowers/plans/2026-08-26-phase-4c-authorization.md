# Phase 4c: Authorization (ACP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce access control on every tenant-scoped resource across all 3 transports (LDP HTTP, SSE, WebSocket), using an ACP-inspired policy model (Policies gated by Matchers, allow/deny with deny-precedence, container inheritance) with default-deny and an implicit first-authenticated-write bootstrap so no separate tenant registry is needed.

**Architecture:** A new `Riptide.Authz` namespace: a pure `evaluate/4` decision function, storage behind a pluggable `Riptide.Authz.Store` behaviour whose default implementation extends the *existing* shared placement Ra cluster (`Riptide.Placement.PlacementMachine`) with new command types — the same way Phase 3d-ii added `{:replace_member, ...}` alongside `{:assign, ...}` — rather than standing up a second Ra cluster. A new `RiptideWeb.Plugs.Authorize` enforces this on LDP HTTP routes; SSE and the WebSocket channel call `Riptide.Authz.evaluate/4` directly after recovering `tenant_id`/path from their opaque `stream_id` via a new `parse_stream_id/1`.

**Tech Stack:** Elixir/Phoenix, Plug, ExUnit, `:ra` (already a dependency, no new one this phase).

**Spec:** `docs/superpowers/specs/2026-08-26-phase-4c-authorization-design.md`

## Global Constraints

- Default-deny: a resource with no matching policy at all is denied, not allowed.
- Only 2 access modes exist: `:read` (GET) and `:write` (POST/PUT/PATCH/DELETE). No `Control` mode.
- Deny always overrides allow when both match the same request.
- A policy attached to a path prefix (including the tenant root, `[]`) applies to every resource
  under it, not just an exact path match.
- Anonymous requests (`current_subject == nil`) never bootstrap tenant ownership, whether reading
  or writing — only an authenticated write to a currently-unclaimed tenant can.
- `Riptide.Placement.PlacementMachine`'s `list/1` function must keep returning exactly
  `%{stream_id() => [node()]}` (nothing else mixed in) — `Riptide.Stream.ReplicaHealer.sweep/0`
  calls `Placement.list_all() |> Enum.each(&maybe_repair/1)` and pattern-matches every entry as
  `{stream_id, nodes}`; mixing a policies key into that same map would make it try
  `RaCluster.uid_for/1` on a non-stream-id key and crash the next scheduled sweep. This is why
  Task 1 restructures internal state into `%{streams: ..., policies: ...}` rather than adding a
  `:policies` key directly alongside stream_id keys.
- No `Control` access mode, no policy revocation endpoint, no sub-container policy management
  API, no full Solid ACP compliance (ACRs as discoverable resources, `Link` header discovery,
  client/VC/issuer matchers) — all explicitly out of scope for this phase, per the spec's §3.

---

### Task 1: Restructure `PlacementMachine`'s state to make room for policies

**Files:**
- Modify: `lib/riptide/placement/placement_machine.ex`
- Modify: `test/riptide/placement/placement_machine_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PlacementMachine`'s internal state becomes `%{streams: %{String.t() => [node()]},
  policies: %{String.t() => %{[String.t()] => [term()]}}}`. `list/1`'s external contract is
  unchanged (`%{String.t() => [node()]}`) — this task only prepares the internal shape; the
  `policies` sub-map is unused until Task 2. Consumed by Task 2's new commands.

- [ ] **Step 1: Update the failing tests first — every existing assertion moves under `state.streams`**

Replace the full contents of `test/riptide/placement/placement_machine_test.exs`:

```elixir
defmodule Riptide.Placement.PlacementMachineTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement.PlacementMachine

  test "init/1 starts with empty streams and policies" do
    assert PlacementMachine.init(%{}) == %{streams: %{}, policies: %{}}
  end

  test "apply/3 stores a new stream's node list" do
    state = PlacementMachine.init(%{})

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    assert new_state == %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}}
    assert reply == [:a, :b, :c]
    assert effects == []
  end

  test "apply/3 is idempotent: a second proposal for an already-assigned stream returns the existing assignment" do
    state = PlacementMachine.init(%{})
    {state, _reply, _} = PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:assign, "s1", [:x, :y, :z]}, state)

    assert new_state == %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}}
    assert reply == [:a, :b, :c]
    assert effects == []
  end

  test "apply/3 stores two different streams independently" do
    state = PlacementMachine.init(%{})
    {state, _, _} = PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)
    {state, _, _} = PlacementMachine.apply(%{index: 2}, {:assign, "s2", [:d, :e, :f]}, state)

    assert state == %{streams: %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}, policies: %{}}
  end

  test "get/2 returns the assigned nodes for a known stream" do
    state = %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}}
    assert PlacementMachine.get(state, "s1") == [:a, :b, :c]
  end

  test "get/2 returns nil for an unknown stream" do
    assert PlacementMachine.get(%{streams: %{}, policies: %{}}, "unknown") == nil
  end

  test "list/1 returns only the stream_id => nodes map, not the internal policies state" do
    state = %{streams: %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}, policies: %{"acme" => %{}}}
    assert PlacementMachine.list(state) == %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}
  end

  test "list/1 returns an empty map when nothing is assigned yet" do
    assert PlacementMachine.list(PlacementMachine.init(%{})) == %{}
  end

  test "apply/3 {:replace_member, ...} swaps a dead node for a new one in an existing assignment" do
    state = %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "s1", :b, :z}, state)

    assert new_state == %{streams: %{"s1" => [:a, :z, :c]}, policies: %{}}
    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op if the named dead node is no longer present" do
    state = %{streams: %{"s1" => [:a, :z, :c]}, policies: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:replace_member, "s1", :b, :y}, state)

    assert new_state == %{streams: %{"s1" => [:a, :z, :c]}, policies: %{}}
    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op for an unknown stream_id" do
    state = %{streams: %{}, policies: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "unknown", :a, :b}, state)

    assert new_state == %{streams: %{}, policies: %{}}
    assert reply == nil
    assert effects == []
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/placement/placement_machine_test.exs --trace`
Expected: FAIL — every assertion expects the new `%{streams: ..., policies: ...}` shape, which
`PlacementMachine` doesn't produce yet.

- [ ] **Step 3: Restructure the machine**

Replace the full contents of `lib/riptide/placement/placement_machine.ex`:

```elixir
defmodule Riptide.Placement.PlacementMachine do
  @moduledoc """
  The `:ra_machine` for Riptide's placement metadata cluster — a small,
  fixed-membership Ra cluster (see `Riptide.RaCluster.placement_server_id/1,2`)
  recording which nodes host each stream's Ra replicas, plus (Phase 4c)
  authorization policies. Pure and process-free by design, mirroring
  `Riptide.Stream.RaMachine`: `init/1`/`apply/3` are the only functions Ra
  itself calls; `get/2`/`list/1`/`list_policies/3` are plain query functions
  run via `Riptide.RaCluster.consistent_query/2`.

  Internal state is `%{streams: %{stream_id() => [node()]}, policies:
  %{tenant_id() => %{path_prefix() => [policy()]}}}` — two independent
  namespaces in one already-hardened, already-bootstrapped Ra cluster,
  rather than a second cluster to operate. `list/1`'s own external contract
  is deliberately unchanged (`%{stream_id() => [node()]}` only): it backs
  `Riptide.Placement.list_all/1`, which `Riptide.Stream.ReplicaHealer.sweep/0`
  iterates expecting *only* `{stream_id, nodes}` entries — mixing a policies
  key into that same flat map would make the healer call
  `RaCluster.uid_for/1` on a non-stream-id key and crash its next sweep.
  """
  @behaviour :ra_machine

  @type stream_id :: String.t()
  @type tenant_id :: String.t()
  @type path_prefix :: [String.t()]
  @type policy :: struct()

  @type state :: %{
          streams: %{stream_id() => [node()]},
          policies: %{tenant_id() => %{path_prefix() => [policy()]}}
        }

  @impl :ra_machine
  def init(_config), do: %{streams: %{}, policies: %{}}

  # Idempotent by construction — see Phase 3c-i design spec §4. Since every
  # command is serialized through Raft consensus, whichever proposal for a
  # given stream_id lands in the log first wins; a later, different proposal
  # for the same already-assigned stream_id is silently ignored and the
  # caller gets back the existing (winning) assignment instead of an error.
  # This makes concurrent stream-creation races safe with no extra locking.
  @impl :ra_machine
  def apply(_meta, {:assign, stream_id, proposed_nodes}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, existing_nodes} ->
        {state, existing_nodes, []}

      :error ->
        new_state = put_in(state, [:streams, stream_id], proposed_nodes)
        {new_state, proposed_nodes, []}
    end
  end

  # Idempotent the same way {:assign, ...} is: if `dead_node` is no longer
  # part of `stream_id`'s stored assignment (e.g. a different placement-
  # cluster leader, from a prior Raft term, already won this exact repair),
  # this is a no-op that returns the current assignment unchanged rather
  # than erroring — safe to call redundantly from a racing leader.
  @impl :ra_machine
  def apply(_meta, {:replace_member, stream_id, dead_node, new_node}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, nodes} ->
        if dead_node in nodes do
          new_nodes = replace_in_list(nodes, dead_node, new_node)
          new_state = put_in(state, [:streams, stream_id], new_nodes)
          {new_state, new_nodes, []}
        else
          {state, nodes, []}
        end

      :error ->
        {state, nil, []}
    end
  end

  defp replace_in_list(nodes, dead_node, new_node) do
    Enum.map(nodes, fn n -> if n == dead_node, do: new_node, else: n end)
  end

  @spec get(state(), stream_id()) :: [node()] | nil
  def get(state, stream_id) do
    Map.get(state.streams, stream_id)
  end

  @spec list(state()) :: %{stream_id() => [node()]}
  def list(state), do: state.streams

  @spec list_policies(state(), tenant_id(), path_prefix()) :: [policy()]
  def list_policies(state, tenant_id, path_prefix) do
    state.policies
    |> Map.get(tenant_id, %{})
    |> Map.get(path_prefix, [])
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/placement/placement_machine_test.exs --trace`
Expected: PASS, all 9 tests.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures. `Riptide.Placement.list_all/1`/`Riptide.Stream.ReplicaHealer` go
through `PlacementMachine.list/1`, whose external contract this task deliberately preserved —
their own tests should be completely unaffected.

- [ ] **Step 6: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/placement/placement_machine.ex test/riptide/placement/placement_machine_test.exs
git commit -m "Restructure PlacementMachine state to make room for authorization policies"
```

---

### Task 2: `Riptide.Authz.Policy`, `Riptide.Authz.Store` behaviour, and the new placement commands

**Files:**
- Create: `lib/riptide/authz/policy.ex`
- Create: `lib/riptide/authz/store.ex`
- Create: `lib/riptide/authz/store/placement.ex`
- Modify: `lib/riptide/placement/placement_machine.ex`
- Modify: `lib/riptide/placement.ex`
- Test: `test/riptide/placement/placement_machine_test.exs`
- Test: `test/riptide/placement_test.exs`

**Interfaces:**
- Consumes: `PlacementMachine`'s restructured state (Task 1).
- Produces: `Riptide.Authz.Policy` struct; `Riptide.Authz.Store` behaviour
  (`list_policies/2`, `add_policy/3`, `claim_tenant_if_unclaimed/2`); `Riptide.Authz.Store.Placement`
  (the default implementation); `Riptide.Placement.add_policy/4`, `list_policies/3`,
  `claim_tenant_if_unclaimed/3` (the new wrapper functions `Store.Placement` delegates to, using
  the same `with_ordinal_fallback` machinery `assign/3`/`lookup/2` already use). Consumed by
  Task 3's `Riptide.Authz.evaluate/4`.

- [ ] **Step 1: Write the failing tests for the new `PlacementMachine` commands**

Append to `test/riptide/placement/placement_machine_test.exs` (before the closing `end` of the
module):

```elixir
  test "apply/3 {:add_policy, ...} appends to an empty policy list for a new tenant/prefix" do
    state = PlacementMachine.init(%{})
    policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:add_policy, "acme", [], policy}, state)

    assert new_state == %{streams: %{}, policies: %{"acme" => %{[] => [policy]}}}
    assert reply == :ok
    assert effects == []
  end

  test "apply/3 {:add_policy, ...} appends to an existing policy list rather than replacing it" do
    state = PlacementMachine.init(%{})
    first = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}
    second = %Riptide.Authz.Policy{effect: :deny, modes: [:write], matcher: :authenticated}

    {state, _, _} = PlacementMachine.apply(%{index: 1}, {:add_policy, "acme", [], first}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:add_policy, "acme", [], second}, state)

    assert new_state == %{streams: %{}, policies: %{"acme" => %{[] => [first, second]}}}
    assert reply == :ok
    assert effects == []
  end

  test "apply/3 {:add_policy, ...} keeps different path prefixes independent" do
    state = PlacementMachine.init(%{})
    root_policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}
    child_policy = %Riptide.Authz.Policy{effect: :deny, modes: [:write], matcher: :authenticated}

    {state, _, _} =
      PlacementMachine.apply(%{index: 1}, {:add_policy, "acme", [], root_policy}, state)

    {new_state, _, _} =
      PlacementMachine.apply(%{index: 2}, {:add_policy, "acme", ["secret"], child_policy}, state)

    assert new_state ==
             %{
               streams: %{},
               policies: %{"acme" => %{[] => [root_policy], ["secret"] => [child_policy]}}
             }
  end

  test "apply/3 {:claim_tenant_if_unclaimed, ...} creates a tenant-root owner policy when the tenant has zero policies" do
    state = PlacementMachine.init(%{})

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:claim_tenant_if_unclaimed, "acme", "user-1"}, state)

    assert new_state == %{
             streams: %{},
             policies: %{
               "acme" => %{
                 [] => [
                   %Riptide.Authz.Policy{
                     effect: :allow,
                     modes: [:read, :write],
                     matcher: {:agent, "user-1"}
                   }
                 ]
               }
             }
           }

    assert reply == :claimed
    assert effects == []
  end

  test "apply/3 {:claim_tenant_if_unclaimed, ...} is a no-op if the tenant already has any policy at any prefix" do
    state = PlacementMachine.init(%{})
    existing = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}

    {state, _, _} =
      PlacementMachine.apply(%{index: 1}, {:add_policy, "acme", ["some", "path"], existing}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:claim_tenant_if_unclaimed, "acme", "user-2"}, state)

    assert new_state == state
    assert reply == :already_claimed
    assert effects == []
  end

  test "list_policies/3 returns an empty list for a tenant/prefix with no policies" do
    state = PlacementMachine.init(%{})
    assert PlacementMachine.list_policies(state, "acme", []) == []
  end

  test "list_policies/3 returns exactly the policies stored at that tenant/prefix" do
    policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}
    state = %{streams: %{}, policies: %{"acme" => %{["docs"] => [policy]}}}

    assert PlacementMachine.list_policies(state, "acme", ["docs"]) == [policy]
    assert PlacementMachine.list_policies(state, "acme", []) == []
    assert PlacementMachine.list_policies(state, "other-tenant", ["docs"]) == []
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/placement/placement_machine_test.exs --trace`
Expected: FAIL — `{:add_policy, ...}`/`{:claim_tenant_if_unclaimed, ...}` commands don't exist yet,
and `Riptide.Authz.Policy` doesn't exist yet (compile error).

- [ ] **Step 3: Create `Riptide.Authz.Policy`**

Create `lib/riptide/authz/policy.ex`:

```elixir
defmodule Riptide.Authz.Policy do
  @moduledoc """
  One ACP-inspired access policy: grants (`effect: :allow`) or denies
  (`effect: :deny`) some set of `modes` to whoever `matcher` matches. See
  `Riptide.Authz.evaluate/4` for how a set of policies attached to a
  resource's ancestor path prefixes is combined into a single allow/deny
  decision (deny always overrides allow).
  """

  @type effect :: :allow | :deny
  @type mode :: :read | :write
  @type matcher :: :public | :authenticated | {:agent, String.t()}

  @type t :: %__MODULE__{effect: effect(), modes: [mode()], matcher: matcher()}

  @enforce_keys [:effect, :modes, :matcher]
  defstruct [:effect, :modes, :matcher]
end
```

- [ ] **Step 4: Add the new commands and query function to `PlacementMachine`**

In `lib/riptide/placement/placement_machine.ex`, add (after the existing `{:replace_member, ...}`
`apply/3` clause and its `replace_in_list/3` helper, before `get/2`):

```elixir
  # Same idempotent-by-construction shape as {:assign, ...}: every command is
  # serialized through Raft, so concurrent `add_policy` calls for the same
  # tenant/prefix are safely ordered by the log rather than racing.
  @impl :ra_machine
  def apply(_meta, {:add_policy, tenant_id, path_prefix, policy}, state) do
    existing = state.policies |> Map.get(tenant_id, %{}) |> Map.get(path_prefix, [])
    new_state = put_in(state, [:policies, Access.key(tenant_id, %{}), path_prefix], existing ++ [policy])
    {new_state, :ok, []}
  end

  # A tenant is "unclaimed" if it has zero policies at every path prefix —
  # see the Phase 4c design spec §6. This must be a single Ra command (not a
  # separate list-then-add pair of calls from the caller) so that two
  # different agents racing to claim the same brand-new tenant resolve to
  # exactly one winner, the same way `{:assign, ...}`'s own idempotency
  # relies on Raft's log ordering rather than a caller-side check-then-act.
  @impl :ra_machine
  def apply(_meta, {:claim_tenant_if_unclaimed, tenant_id, subject}, state) do
    if tenant_claimed?(state, tenant_id) do
      {state, :already_claimed, []}
    else
      owner_policy = %Riptide.Authz.Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: {:agent, subject}
      }

      new_state = put_in(state, [:policies, tenant_id], %{[] => [owner_policy]})
      {new_state, :claimed, []}
    end
  end

  defp tenant_claimed?(state, tenant_id) do
    state.policies
    |> Map.get(tenant_id, %{})
    |> Map.values()
    |> Enum.any?(&(&1 != []))
  end
```

Then add `list_policies/3` after the existing `list/1` function:

```elixir
  @spec list_policies(state(), tenant_id(), path_prefix()) :: [policy()]
  def list_policies(state, tenant_id, path_prefix) do
    state.policies
    |> Map.get(tenant_id, %{})
    |> Map.get(path_prefix, [])
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide/placement/placement_machine_test.exs --trace`
Expected: PASS, all 15 tests.

- [ ] **Step 6: Write the failing wrapper-API test in `placement_test.exs`**

Append to `test/riptide/placement_test.exs` (before the closing `end` of the module, inside or
after the existing `describe "assign/2 and lookup/2 against the real metadata cluster"` block —
add as a new top-level `describe`):

```elixir
  describe "add_policy/3, list_policies/2, and claim_tenant_if_unclaimed/2 against the real metadata cluster" do
    test "add_policy/3 then list_policies/2 round-trips a real policy" do
      tenant_id = "authz-test-" <> Uniq.UUID.uuid4()
      policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}

      assert Placement.add_policy(tenant_id, [], policy) == :ok
      assert Placement.list_policies(tenant_id, []) == [policy]
    end

    test "list_policies/2 returns an empty list for a tenant/prefix with no policies" do
      tenant_id = "authz-test-empty-" <> Uniq.UUID.uuid4()
      assert Placement.list_policies(tenant_id, []) == []
    end

    test "claim_tenant_if_unclaimed/2 claims a brand-new tenant exactly once" do
      tenant_id = "authz-claim-test-" <> Uniq.UUID.uuid4()

      assert Placement.claim_tenant_if_unclaimed(tenant_id, "user-1") == :claimed
      assert Placement.claim_tenant_if_unclaimed(tenant_id, "user-2") == :already_claimed

      assert Placement.list_policies(tenant_id, []) == [
               %Riptide.Authz.Policy{effect: :allow, modes: [:read, :write], matcher: {:agent, "user-1"}}
             ]
    end

    test "claim_tenant_if_unclaimed/2 resolves a real race between two simultaneous claims to exactly one winner" do
      tenant_id = "authz-claim-race-test-" <> Uniq.UUID.uuid4()

      results =
        [
          Task.async(fn -> Placement.claim_tenant_if_unclaimed(tenant_id, "racer-1") end),
          Task.async(fn -> Placement.claim_tenant_if_unclaimed(tenant_id, "racer-2") end)
        ]
        |> Enum.map(&Task.await/1)

      assert Enum.sort(results) == [:already_claimed, :claimed]

      # Exactly one owner policy exists afterward, for whichever racer's
      # command Raft's log actually ordered first — never both, never
      # neither. Every command against this Ra cluster is serialized
      # through consensus, so this proves the race is resolved by the log
      # itself rather than by any check-then-act ordering on the caller side.
      assert [%Riptide.Authz.Policy{matcher: {:agent, winner}}] = Placement.list_policies(tenant_id, [])
      assert winner in ["racer-1", "racer-2"]
    end
  end
```

- [ ] **Step 7: Run the test to verify it fails**

Run: `mix test test/riptide/placement_test.exs --trace`
Expected: FAIL — `Riptide.Placement.add_policy/3`, `list_policies/2`, and
`claim_tenant_if_unclaimed/2` don't exist yet.

- [ ] **Step 8: Add the wrapper functions to `Riptide.Placement`**

In `lib/riptide/placement.ex`, add (after the existing `replace_member/4` function, before the
`with_ordinal_fallback/2` private helper):

```elixir
  @spec add_policy(String.t(), [String.t()], Riptide.Authz.Policy.t(), (String.t() -> node())) ::
          :ok
  def add_policy(
        tenant_id,
        path_prefix,
        policy,
        resolve_fun \\ &RaCluster.default_ordinal_resolver/1
      ) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.process_command(server_id, {:add_policy, tenant_id, path_prefix, policy})
    end)
  end

  @spec list_policies(String.t(), [String.t()], (String.t() -> node())) :: [
          Riptide.Authz.Policy.t()
        ]
  def list_policies(tenant_id, path_prefix, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.consistent_query(server_id, &PlacementMachine.list_policies(&1, tenant_id, path_prefix))
    end)
  end

  @spec claim_tenant_if_unclaimed(String.t(), String.t(), (String.t() -> node())) ::
          :claimed | :already_claimed
  def claim_tenant_if_unclaimed(
        tenant_id,
        subject,
        resolve_fun \\ &RaCluster.default_ordinal_resolver/1
      ) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.process_command(server_id, {:claim_tenant_if_unclaimed, tenant_id, subject})
    end)
  end
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `mix test test/riptide/placement_test.exs --trace`
Expected: PASS, all tests including the 4 new ones.

- [ ] **Step 10: Create the `Riptide.Authz.Store` behaviour**

Create `lib/riptide/authz/store.ex`:

```elixir
defmodule Riptide.Authz.Store do
  @moduledoc """
  Behaviour for where `Riptide.Authz.Policy` structs are persisted. Selected
  via `Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)`
  — the same config-driven swap `Riptide.Auth.Verifier`/`Riptide.Tenancy.Resolver`
  already use (Phases 3c-i/4a/4b), so tests can inject a fake store the same
  way `config/test.exs` overrides the ordinal resolver.
  """

  alias Riptide.Authz.Policy

  @callback list_policies(tenant_id :: String.t(), path_prefix :: [String.t()]) :: [Policy.t()]
  @callback add_policy(tenant_id :: String.t(), path_prefix :: [String.t()], Policy.t()) :: :ok
  @callback claim_tenant_if_unclaimed(tenant_id :: String.t(), subject :: String.t()) ::
              :claimed | :already_claimed
end
```

- [ ] **Step 11: Create the default `Riptide.Authz.Store.Placement` implementation**

Create `lib/riptide/authz/store/placement.ex`:

```elixir
defmodule Riptide.Authz.Store.Placement do
  @moduledoc """
  Default `Riptide.Authz.Store` implementation — persists policies through
  the existing shared placement Ra cluster (`Riptide.Placement`), rather
  than a second Ra cluster to bootstrap and operate (see Phase 4c design
  spec §4).
  """
  @behaviour Riptide.Authz.Store

  alias Riptide.Placement

  @impl true
  def list_policies(tenant_id, path_prefix), do: Placement.list_policies(tenant_id, path_prefix)

  @impl true
  def add_policy(tenant_id, path_prefix, policy),
    do: Placement.add_policy(tenant_id, path_prefix, policy)

  @impl true
  def claim_tenant_if_unclaimed(tenant_id, subject),
    do: Placement.claim_tenant_if_unclaimed(tenant_id, subject)
end
```

- [ ] **Step 12: Write a smoke test proving `Store.Placement` really delegates to the real cluster**

Create `test/riptide/authz/store/placement_test.exs`:

```elixir
defmodule Riptide.Authz.Store.PlacementTest do
  use ExUnit.Case, async: true

  alias Riptide.Authz.{Policy, Store}

  test "add_policy/3 then list_policies/2 round-trips through the real placement cluster" do
    tenant_id = "authz-store-test-" <> Uniq.UUID.uuid4()
    policy = %Policy{effect: :deny, modes: [:write], matcher: :authenticated}

    assert Store.Placement.add_policy(tenant_id, ["docs"], policy) == :ok
    assert Store.Placement.list_policies(tenant_id, ["docs"]) == [policy]
  end

  test "claim_tenant_if_unclaimed/2 claims a brand-new tenant exactly once" do
    tenant_id = "authz-store-claim-test-" <> Uniq.UUID.uuid4()

    assert Store.Placement.claim_tenant_if_unclaimed(tenant_id, "user-1") == :claimed
    assert Store.Placement.claim_tenant_if_unclaimed(tenant_id, "user-2") == :already_claimed
  end
end
```

- [ ] **Step 13: Run the test to verify it passes**

Run: `mix test test/riptide/authz/store/placement_test.exs --trace`
Expected: PASS, both tests.

- [ ] **Step 14: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 15: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean. Fix anything flagged and re-run.

- [ ] **Step 16: Commit**

```bash
git add lib/riptide/authz/policy.ex lib/riptide/authz/store.ex lib/riptide/authz/store/placement.ex \
        lib/riptide/placement/placement_machine.ex lib/riptide/placement.ex \
        test/riptide/placement/placement_machine_test.exs test/riptide/placement_test.exs \
        test/riptide/authz/store/placement_test.exs
git commit -m "Add Riptide.Authz.Policy/Store + placement-cluster-backed default Store implementation"
```

---

### Task 3: `Riptide.Authz.evaluate/4`

**Files:**
- Create: `lib/riptide/authz.ex`
- Test: `test/riptide/authz_test.exs`

**Interfaces:**
- Consumes: `Riptide.Authz.Policy` (Task 2), `Riptide.Authz.Store` behaviour via
  `Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)`.
- Produces: `Riptide.Authz.evaluate(tenant_id, path_segments, current_subject, mode) :: :allow |
  :deny`. Consumed by Task 4's `Authorize` plug and Tasks 7-8's SSE/WebSocket wiring.

- [ ] **Step 1: Write the failing tests against a fake `Store`**

Create `test/riptide/authz_test.exs`:

```elixir
defmodule Riptide.AuthzTest do
  use ExUnit.Case, async: false

  alias Riptide.Authz
  alias Riptide.Authz.Policy

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies(tenant_id, path_prefix) do
      Agent.get(__MODULE__, &Map.get(&1, {tenant_id, path_prefix}, []))
    end

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok

    @impl true
    def claim_tenant_if_unclaimed(_tenant_id, _subject), do: :already_claimed

    def start(policies_by_prefix) do
      case Agent.start_link(fn -> policies_by_prefix end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  setup do
    original = Application.get_env(:riptide, :authz_store)
    Application.put_env(:riptide, :authz_store, FakeStore)

    on_exit(fn ->
      Application.put_env(:riptide, :authz_store, original)
      if pid = Process.whereis(FakeStore), do: Agent.stop(pid)
    end)

    :ok
  end

  test "denies when no policy matches at all (default-deny)" do
    FakeStore.start(%{})
    assert Authz.evaluate("acme", ["docs"], %{"sub" => "user-1"}, :read) == :deny
  end

  test "a :public matcher allows anyone, including anonymous, for the modes it lists" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
    })

    assert Authz.evaluate("acme", ["docs"], nil, :read) == :allow
    assert Authz.evaluate("acme", ["docs"], %{"sub" => "someone"}, :read) == :allow
    assert Authz.evaluate("acme", ["docs"], nil, :write) == :deny
  end

  test "an :authenticated matcher allows any non-nil subject but not anonymous" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :authenticated}]
    })

    assert Authz.evaluate("acme", ["docs"], %{"sub" => "someone"}, :read) == :allow
    assert Authz.evaluate("acme", ["docs"], nil, :read) == :deny
  end

  test "an {:agent, subject} matcher only allows that exact subject" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read, :write], matcher: {:agent, "owner"}}]
    })

    assert Authz.evaluate("acme", ["docs"], %{"sub" => "owner"}, :write) == :allow
    assert Authz.evaluate("acme", ["docs"], %{"sub" => "someone-else"}, :write) == :deny
  end

  test "a policy only grants the modes it explicitly lists" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
    })

    assert Authz.evaluate("acme", ["docs"], nil, :read) == :allow
    assert Authz.evaluate("acme", ["docs"], nil, :write) == :deny
  end

  test "deny overrides allow when both match the same request" do
    FakeStore.start(%{
      {"acme", []} => [
        %Policy{effect: :allow, modes: [:read], matcher: :public},
        %Policy{effect: :deny, modes: [:read], matcher: :authenticated}
      ]
    })

    # Anonymous: only the :public allow matches -> allow.
    assert Authz.evaluate("acme", ["docs"], nil, :read) == :allow
    # Authenticated: both the :public allow and the :authenticated deny match -> deny wins.
    assert Authz.evaluate("acme", ["docs"], %{"sub" => "someone"}, :read) == :deny
  end

  test "a policy on an ancestor container is inherited by a deeper resource" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
    })

    assert Authz.evaluate("acme", ["docs", "sub", "deep"], nil, :read) == :allow
  end

  test "a policy on a sibling path prefix does not apply to an unrelated resource" do
    FakeStore.start(%{
      {"acme", ["other"]} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
    })

    assert Authz.evaluate("acme", ["docs"], nil, :read) == :deny
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/authz_test.exs --trace`
Expected: FAIL — `Riptide.Authz` doesn't exist yet.

- [ ] **Step 3: Implement `Riptide.Authz.evaluate/4`**

Create `lib/riptide/authz.ex`:

```elixir
defmodule Riptide.Authz do
  @moduledoc """
  Transport-agnostic authorization decision point — called identically from
  `RiptideWeb.Plugs.Authorize` (LDP HTTP), `RiptideWeb.Realtime.SseController`,
  and `RiptideWeb.Realtime.ReplicationChannel` (Tasks 4, 7, 8), the same way
  `Riptide.Auth.Verifier`'s `verify/1` is called identically from
  `RiptideWeb.Plugs.Authenticate` and `RiptideWeb.Realtime.Socket.connect/3`
  (Phase 4b). See the Phase 4c design spec §5 for the algorithm this
  implements.
  """

  alias Riptide.Authz.Policy

  @spec evaluate(String.t(), [String.t()], map() | nil, Policy.mode()) :: :allow | :deny
  def evaluate(tenant_id, path_segments, current_subject, mode) do
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)

    matching_policies =
      path_segments
      |> prefixes()
      |> Enum.flat_map(&store.list_policies(tenant_id, &1))
      |> Enum.filter(&applies?(&1, current_subject, mode))

    cond do
      Enum.any?(matching_policies, &(&1.effect == :deny)) -> :deny
      Enum.any?(matching_policies, &(&1.effect == :allow)) -> :allow
      true -> :deny
    end
  end

  # Every prefix of path_segments, including the empty one (the tenant
  # root): for ["docs", "sub"] this is [[], ["docs"], ["docs", "sub"]] — an
  # ancestor container's policies apply to everything under it.
  defp prefixes(path_segments) do
    Enum.map(0..length(path_segments), &Enum.take(path_segments, &1))
  end

  defp applies?(%Policy{matcher: matcher, modes: modes}, current_subject, mode) do
    mode in modes and matches?(matcher, current_subject)
  end

  defp matches?(:public, _current_subject), do: true
  defp matches?(:authenticated, current_subject), do: not is_nil(current_subject)

  defp matches?({:agent, subject}, current_subject),
    do: not is_nil(current_subject) and current_subject["sub"] == subject
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/authz_test.exs --trace`
Expected: PASS, all 8 tests.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/authz.ex test/riptide/authz_test.exs
git commit -m "Add Riptide.Authz.evaluate/4"
```

---

### Task 4: `RiptideWeb.Plugs.Authorize`

**Files:**
- Create: `lib/riptide_web/plugs/authorize.ex`
- Test: `test/riptide_web/plugs/authorize_test.exs`

**Interfaces:**
- Consumes: `Riptide.Authz.evaluate/4` (Task 3), `Application.get_env(:riptide, :authz_store,
  Riptide.Authz.Store.Placement)`.
- Produces: `RiptideWeb.Plugs.Authorize`, halting with `403` on deny, falling through
  (unmodified `conn`) on allow. Consumed by Task 5's router wiring.

This task's own tests use a fake `Store` (config-injected, same pattern as Task 3's `FakeStore`)
to isolate the plug's own request-shape/mode-mapping/bootstrap-dispatch logic from the real Ra
cluster, which Task 2 already covers.

- [ ] **Step 1: Write the failing tests**

Create `test/riptide_web/plugs/authorize_test.exs`:

```elixir
defmodule RiptideWeb.Plugs.AuthorizeTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias RiptideWeb.Plugs.Authorize

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies("acme", []),
      do: [%Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}]

    def list_policies(_tenant_id, _path_prefix), do: []

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok

    @impl true
    def claim_tenant_if_unclaimed("unclaimed-tenant", _subject), do: :claimed
    def claim_tenant_if_unclaimed(_tenant_id, _subject), do: :already_claimed
  end

  setup do
    original = Application.get_env(:riptide, :authz_store)
    Application.put_env(:riptide, :authz_store, FakeStore)
    on_exit(fn -> Application.put_env(:riptide, :authz_store, original) end)
    :ok
  end

  defp conn_for(method, tenant_id, path_segments, current_subject) do
    method
    |> conn("/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/"))
    |> Map.update!(:params, &Map.put(&1, "path", path_segments))
    |> assign(:tenant_id, tenant_id)
    |> assign(:current_subject, current_subject)
  end

  test "allows a GET matching a public policy, for an anonymous request" do
    conn =
      :get
      |> conn_for("acme", ["docs"], nil)
      |> Authorize.call(Authorize.init([]))

    refute conn.halted
  end

  test "denies a POST/PUT/PATCH/DELETE with no matching write policy" do
    for method <- [:post, :put, :patch, :delete] do
      conn =
        method
        |> conn_for("acme", ["docs"], %{"sub" => "someone"})
        |> Authorize.call(Authorize.init([]))

      assert conn.halted
      assert conn.status == 403
    end
  end

  test "denies a GET with no matching policy at all" do
    conn =
      :get
      |> conn_for("no-such-tenant", ["docs"], nil)
      |> Authorize.call(Authorize.init([]))

    assert conn.halted
    assert conn.status == 403
  end

  test "an authenticated write to an unclaimed tenant bootstraps ownership and is allowed" do
    conn =
      :put
      |> conn_for("unclaimed-tenant", ["docs"], %{"sub" => "user-1"})
      |> Authorize.call(Authorize.init([]))

    refute conn.halted
  end

  test "an anonymous write to an unclaimed tenant is denied, not treated as a claim attempt" do
    conn =
      :put
      |> conn_for("unclaimed-tenant", ["docs"], nil)
      |> Authorize.call(Authorize.init([]))

    assert conn.halted
    assert conn.status == 403
  end

  test "a read (never a write) never bootstraps ownership even when authenticated" do
    conn =
      :get
      |> conn_for("unclaimed-tenant", ["docs"], %{"sub" => "user-1"})
      |> Authorize.call(Authorize.init([]))

    assert conn.halted
    assert conn.status == 403
  end

  test "an authenticated write to an already-claimed tenant with no matching policy is denied" do
    conn =
      :put
      |> conn_for("already-claimed-tenant", ["docs"], %{"sub" => "someone"})
      |> Authorize.call(Authorize.init([]))

    assert conn.halted
    assert conn.status == 403
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/plugs/authorize_test.exs --trace`
Expected: FAIL — `RiptideWeb.Plugs.Authorize` doesn't exist yet.

- [ ] **Step 3: Implement the plug**

Create `lib/riptide_web/plugs/authorize.ex`:

```elixir
defmodule RiptideWeb.Plugs.Authorize do
  @moduledoc """
  Enforces `Riptide.Authz.evaluate/4`'s decision on every tenant-scoped LDP
  route — mirrors `RiptideWeb.Plugs.ResolveTenant`/`Authenticate`'s shape.
  Halts with `403` on deny.

  On an otherwise-denied *authenticated write*, first checks whether the
  tenant is still unclaimed (see the Phase 4c design spec §6):
  `Riptide.Authz.Store.claim_tenant_if_unclaimed/2` is a single atomic Ra
  command, not a separate check-then-add pair of calls, so a race between
  two different agents both attempting to be "first write" to the same
  brand-new tenant resolves to exactly one owner. Anonymous requests and
  reads never reach this path — they're just denied.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    tenant_id = conn.assigns.tenant_id
    current_subject = conn.assigns.current_subject
    path_segments = conn.params["path"] || []
    mode = mode_for(conn.method)

    case Riptide.Authz.evaluate(tenant_id, path_segments, current_subject, mode) do
      :allow -> conn
      :deny -> maybe_bootstrap(conn, tenant_id, current_subject, mode)
    end
  end

  defp maybe_bootstrap(conn, tenant_id, current_subject, :write)
       when not is_nil(current_subject) do
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)

    case store.claim_tenant_if_unclaimed(tenant_id, current_subject["sub"]) do
      :claimed -> conn
      :already_claimed -> reject(conn)
    end
  end

  defp maybe_bootstrap(conn, _tenant_id, _current_subject, _mode), do: reject(conn)

  defp mode_for("GET"), do: :read
  defp mode_for(_other), do: :write

  defp reject(conn) do
    conn
    |> send_resp(403, "")
    |> halt()
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide_web/plugs/authorize_test.exs --trace`
Expected: PASS, all 7 tests.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide_web/plugs/authorize.ex test/riptide_web/plugs/authorize_test.exs
git commit -m "Add RiptideWeb.Plugs.Authorize"
```

---

### Task 5: Wire `Authorize` into the router for LDP resource routes

**Files:**
- Modify: `lib/riptide_web/router.ex`
- Modify: `test/riptide_web/ldp/resource_controller_test.exs`

**Interfaces:**
- Consumes: `RiptideWeb.Plugs.Authorize` (Task 4).
- Produces: every tenant-scoped LDP resource route now runs `Authorize` after `:tenant`/`:auth`.
  No other task depends on this one directly, but Task 9's policy management routes reuse the
  same `:authz` pipeline this task creates.

- [ ] **Step 1: Switch the file to `async: false` — these new tests mutate global config**

`test/riptide_web/ldp/resource_controller_test.exs` currently declares `use ExUnit.Case, async:
true`. The new authorization tests below call `Application.put_env(:riptide, :auth_verifier,
...)` to inject a stub verifier — global, process-wide mutable state — exactly the hazard Phase
4b's `Authenticate`/`ResolveTenant`/SSE test files already had to declare `async: false` for (see
their own `setup`/`on_exit` blocks). Running this file `async: true` risks a *different*
concurrently-running async test hitting real `Authenticate`-gated code with the wrong verifier
mid-flight. Change line 2 from:

```elixir
  use ExUnit.Case, async: true
```

to:

```elixir
  use ExUnit.Case, async: false
```

- [ ] **Step 2: Write the failing end-to-end tests**

Add to `test/riptide_web/ldp/resource_controller_test.exs` — this exercises the *real*
`Store.Placement` (no config override), the same way the rest of that file already exercises the
real placement/stream infrastructure. Add near the end of the file, before the closing `end`:

```elixir
  describe "authorization" do
    test "an anonymous GET of a never-written resource in a brand-new tenant is denied with 403, not 404" do
      tenant_id = "authz-e2e-" <> Uniq.UUID.uuid4()
      path = "/tenants/#{tenant_id}/resources/doc"

      conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "the first authenticated write to a brand-new tenant claims ownership and succeeds" do
      tenant_id = "authz-e2e-" <> Uniq.UUID.uuid4()
      path = "/tenants/#{tenant_id}/resources/doc"
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(tenant_id, path)) end)

      owner_claims = %{"sub" => "owner-" <> Uniq.UUID.uuid4()}
      Application.put_env(:riptide, :authz_test_verifier_claims, owner_claims)
      on_exit(fn -> Application.delete_env(:riptide, :authz_test_verifier_claims) end)

      original_verifier = Application.get_env(:riptide, :auth_verifier)
      Application.put_env(:riptide, :auth_verifier, RiptideWeb.LDP.ResourceControllerTest.StubOwnerVerifier)
      on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original_verifier) end)

      put_conn =
        :put
        |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"z\" .\n")
        |> put_req_header("content-type", "text/turtle")
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert put_conn.status == 201

      get_conn =
        :get
        |> conn(path)
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert get_conn.status == 200
      assert get_conn.resp_body =~ "\"z\""
    end

    test "a different identity is denied access to an already-claimed tenant's resource" do
      tenant_id = "authz-e2e-" <> Uniq.UUID.uuid4()
      path = "/tenants/#{tenant_id}/resources/doc"
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(tenant_id, path)) end)

      original_verifier = Application.get_env(:riptide, :auth_verifier)
      Application.put_env(:riptide, :auth_verifier, RiptideWeb.LDP.ResourceControllerTest.StubOwnerVerifier)
      on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original_verifier) end)

      :put
      |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"z\" .\n")
      |> put_req_header("content-type", "text/turtle")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

      other_get_conn =
        :get
        |> conn(path)
        |> put_req_header("authorization", "Bearer someone-else-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert other_get_conn.status == 403

      owner_get_conn =
        :get
        |> conn(path)
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert owner_get_conn.status == 200
    end
  end

  defmodule StubOwnerVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify(_token), do: {:error, :invalid_token}
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs --trace`
Expected: FAIL — the router doesn't run `Authorize` on these routes yet, so every request
succeeds/404s exactly as before (no `403`s at all).

- [ ] **Step 4: Update the router**

Replace the full contents of `lib/riptide_web/router.ex`:

```elixir
defmodule RiptideWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json", "turtle", "ld+json"]
  end

  pipeline :tenant do
    plug RiptideWeb.Plugs.ResolveTenant
  end

  pipeline :auth do
    plug RiptideWeb.Plugs.Authenticate
  end

  pipeline :authz do
    plug RiptideWeb.Plugs.Authorize
  end

  scope "/" do
    pipe_through :api

    get "/health", RiptideWeb.HealthController, :show
  end

  scope "/" do
    pipe_through [:api, :auth]

    get "/streams/:stream_id/subscribe", RiptideWeb.Realtime.SseController, :subscribe
  end

  scope "/tenants/:tenant_id" do
    pipe_through [:api, :tenant, :auth, :authz]

    get "/resources/*path", RiptideWeb.LDP.ResourceController, :show
    post "/resources/*path", RiptideWeb.LDP.ResourceController, :create_child
    put "/resources/*path", RiptideWeb.LDP.ResourceController, :replace
    delete "/resources/*path", RiptideWeb.LDP.ResourceController, :delete
    patch "/resources/*path", RiptideWeb.LDP.ResourceController, :patch
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs --trace`
Expected: PASS, all tests including the 3 new authorization ones.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — every *other* existing test in this file uses `unique_stream_id()`
(a brand-new tenant per test) with **no** `Authorization` header, so under the old expectations
those would now all get `403` instead of their previous status codes. Read the file's existing
tests before this step: they need updating to also claim ownership first (via one authenticated
`PUT`/`POST` using a stub verifier, or by pre-seeding a `:public` `allow` policy via
`Riptide.Authz.Store.Placement.add_policy/3` in each test's own setup) — do that now, choosing
whichever keeps each existing test's own assertions about resource behavior (not authorization)
unchanged. The straightforward option: add a `setup` block to the whole
`RiptideWeb.LDP.ResourceControllerTest` module that seeds a `:public`, `[:read, :write]` `allow`
policy for whatever `tenant_id` each test's `unique_stream_id()`-equivalent helper uses, via
`Riptide.Authz.Store.Placement.add_policy(tenant_id, [], %Riptide.Authz.Policy{effect: :allow,
modes: [:read, :write], matcher: :public})`, so pre-existing tests keep exercising anonymous
access exactly as before, and only the new `describe "authorization"` block exercises real
identity-based restrictions.

- [ ] **Step 7: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 8: Commit**

```bash
git add lib/riptide_web/router.ex test/riptide_web/ldp/resource_controller_test.exs
git commit -m "Wire RiptideWeb.Plugs.Authorize into the router for LDP resource routes"
```

---

### Task 6: `parse_stream_id/1`

**Files:**
- Modify: `lib/riptide_web/ldp/resource_controller.ex`
- Test: `test/riptide_web/ldp/resource_controller_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `RiptideWeb.LDP.ResourceController.stream_id_for/2` becomes public;
  `RiptideWeb.LDP.ResourceController.parse_stream_id/1 :: {:ok, String.t(), [String.t()]} |
  :error`. Consumed by Task 7 (SSE) and Task 8 (WebSocket).

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide_web/ldp/resource_controller_test.exs`, near the top-level tests (not inside
the `describe "authorization"` block):

```elixir
  describe "stream_id_for/2 and parse_stream_id/1" do
    test "parse_stream_id/1 recovers the exact tenant_id and path_segments stream_id_for/2 was built from" do
      stream_id = ResourceController.stream_id_for("acme", ["docs", "sub"])
      assert ResourceController.parse_stream_id(stream_id) == {:ok, "acme", ["docs", "sub"]}
    end

    test "parse_stream_id/1 round-trips for a single-segment path" do
      stream_id = ResourceController.stream_id_for("acme", ["doc"])
      assert ResourceController.parse_stream_id(stream_id) == {:ok, "acme", ["doc"]}
    end

    test "parse_stream_id/1 returns :error for a stream_id not shaped like a tenant resource" do
      assert ResourceController.parse_stream_id("not-a-real-stream-id") == :error
      assert ResourceController.parse_stream_id("https://riptide.example/health") == :error
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs --trace`
Expected: FAIL — `parse_stream_id/1` doesn't exist yet, and `stream_id_for/2` is currently
private (a direct call from the test module wouldn't compile).

- [ ] **Step 3: Make `stream_id_for/2` public and add `parse_stream_id/1`**

In `lib/riptide_web/ldp/resource_controller.ex`, replace:

```elixir
  defp stream_id_for(tenant_id, path_segments) do
    "https://riptide.example/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/")
  end
```

with:

```elixir
  @stream_id_prefix "https://riptide.example/tenants/"
  @resources_segment "/resources/"

  @spec stream_id_for(String.t(), [String.t()]) :: String.t()
  def stream_id_for(tenant_id, path_segments) do
    @stream_id_prefix <> tenant_id <> @resources_segment <> Enum.join(path_segments, "/")
  end

  # The exact inverse of `stream_id_for/2` — used by Phase 4c's authorization
  # layer (`RiptideWeb.Realtime.SseController`/`ReplicationChannel`, Tasks 7-8)
  # to recover which tenant/resource an opaque, client-supplied `stream_id`
  # addresses, since neither transport constructs one from a path
  # server-side (see Phase 4a design spec §5, Phase 4c design spec §7).
  # `stream_id_for/2`'s format is a pure, deterministic, reversible string —
  # no hashing or randomness — so parsing it back apart needs no new
  # persisted state, at the cost of staying coupled to this exact format:
  # the round-trip tests in `resource_controller_test.exs` exist specifically
  # to catch a future change here breaking that coupling silently.
  @spec parse_stream_id(String.t()) :: {:ok, String.t(), [String.t()]} | :error
  def parse_stream_id(@stream_id_prefix <> rest) do
    case String.split(rest, @resources_segment, parts: 2) do
      [tenant_id, path] when tenant_id != "" -> {:ok, tenant_id, String.split(path, "/")}
      _ -> :error
    end
  end

  def parse_stream_id(_other), do: :error
```

Every other call site in this module already calls `stream_id_for(...)` unqualified from within
the same module, so making it public requires no other changes in this file.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs --trace`
Expected: PASS, all tests including the 3 new ones.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide_web/ldp/resource_controller.ex test/riptide_web/ldp/resource_controller_test.exs
git commit -m "Add RiptideWeb.LDP.ResourceController.parse_stream_id/1"
```

---

### Task 7: SSE authorization

**Files:**
- Modify: `lib/riptide_web/realtime/sse_controller.ex`
- Modify: `test/riptide_web/realtime/sse_controller_test.exs`

**Interfaces:**
- Consumes: `Riptide.Authz.evaluate/4` (Task 3), `RiptideWeb.LDP.ResourceController.parse_stream_id/1`
  (Task 6).
- Produces: `SseController.subscribe/2` denies with `403` when the parsed tenant/path fails
  authorization for `:read`. No other task depends on this one.

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide_web/realtime/sse_controller_test.exs`, inside the existing
`describe "authentication"` block's sibling scope (add a new `describe "authorization"` block
after it, before the closing `end` of the module):

```elixir
  describe "authorization" do
    test "subscribing to a stream_id shaped like a tenant resource with no matching policy is denied with 403" do
      tenant_id = "sse-authz-test-" <> Uniq.UUID.uuid4()
      stream_id = RiptideWeb.LDP.ResourceController.stream_id_for(tenant_id, ["doc"])

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "subscribing to a stream_id shaped like a tenant resource with a public read policy succeeds" do
      tenant_id = "sse-authz-test-" <> Uniq.UUID.uuid4()
      stream_id = RiptideWeb.LDP.ResourceController.stream_id_for(tenant_id, ["doc"])
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

      :ok =
        Riptide.Authz.Store.Placement.add_policy(tenant_id, [], %Riptide.Authz.Policy{
          effect: :allow,
          modes: [:read],
          matcher: :public
        })

      Riptide.Stream.StreamSupervisor.ensure_ready(stream_id)

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 200
    end

    test "a stream_id not shaped like a tenant resource (e.g. a legacy non-tenant-scoped id) is denied, not crashed" do
      conn =
        :get
        |> conn("/streams/some-legacy-stream-id/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/realtime/sse_controller_test.exs --trace`
Expected: FAIL — `SseController.subscribe/2` doesn't check authorization yet, so the first and
third tests get something other than `403` (whatever `StreamSupervisor.ensure_ready/1` naturally
returns for a stream_id no test has written to, or a crash on the unparseable legacy id).

- [ ] **Step 3: Wire authorization into `SseController.subscribe/2`**

Replace the full contents of `lib/riptide_web/realtime/sse_controller.ex`:

```elixir
defmodule RiptideWeb.Realtime.SseController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  def subscribe(conn, %{"stream_id" => stream_id}) do
    with {:ok, tenant_id, path_segments} <- ResourceController.parse_stream_id(stream_id),
         :allow <- Riptide.Authz.evaluate(tenant_id, path_segments, conn.assigns.current_subject, :read) do
      do_subscribe(conn, stream_id)
    else
      _ -> send_resp(conn, 403, "")
    end
  end

  defp do_subscribe(conn, stream_id) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)
        cursor = last_event_id(conn)

        case StreamServer.get_since(stream_id, cursor) do
          {:gap, oldest} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(409, Jason.encode!(%{"oldestAvailable" => oldest}))

          {:ok, backlog} ->
            conn =
              conn
              |> put_resp_content_type("text/event-stream", nil)
              |> send_chunked(200)

            conn = Enum.reduce(backlog, conn, &write_event(&2, &1))
            loop(conn)
        end

      :error ->
        send_resp(conn, 503, "")
    end
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

  defp loop(conn) do
    receive do
      {:new_event, event} ->
        conn = write_event(conn, event)
        loop(conn)
    after
      1_000 -> conn
    end
  end

  defp write_event(conn, event) do
    {:ok, turtle} = TurtleCodec.encode(Event.wire_payload(event))
    frame = "id: #{event.sequence}\ndata: #{String.replace(turtle, "\n", "\ndata: ")}\n\n"
    {:ok, conn} = Plug.Conn.chunk(conn, frame)
    conn
  end

  defp last_event_id(conn) do
    case Plug.Conn.get_req_header(conn, "last-event-id") do
      [id] -> String.to_integer(id)
      [] -> nil
    end
  end
end
```

Note the existing `describe "authentication"` block's 3 tests (`no token still succeeds`, `valid
?token=`, `invalid token rejected with 401`) all use `unique_auth_stream_id()`-generated stream
ids with **no** policy seeded for their tenant — after this change they would now get `403`
instead of their previously-expected `200`/`401`. Fix this the same way Task 5 fixed
`resource_controller_test.exs`: add a policy-seeding `setup` (or inline `add_policy` calls) to
this file too, granting `:public`, `[:read]` access for whatever tenant those pre-existing tests'
stream ids resolve to, so their own assertions about *authentication* behavior stay meaningful and
unchanged by *authorization* now also being enforced.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide_web/realtime/sse_controller_test.exs --trace`
Expected: PASS, all tests.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide_web/realtime/sse_controller.ex test/riptide_web/realtime/sse_controller_test.exs
git commit -m "Add SSE authorization via Riptide.Authz.evaluate/4"
```

---

### Task 8: WebSocket authorization

**Files:**
- Modify: `lib/riptide_web/realtime/replication_channel.ex`
- Modify: `test/riptide_web/realtime/replication_channel_test.exs`

**Interfaces:**
- Consumes: `Riptide.Authz.evaluate/4` (Task 3), `RiptideWeb.LDP.ResourceController.parse_stream_id/1`
  (Task 6), `socket.assigns.current_subject` (Phase 4b).
- Produces: `ReplicationChannel.join/3` denies with `{:error, %{"reason" => "unauthorized"}}` when
  the parsed tenant/path fails authorization for `:read`. No other task depends on this one.

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide_web/realtime/replication_channel_test.exs`, after the existing 3 auth tests
added in Phase 4b (before the closing `end` of the module):

```elixir
  test "joining a topic shaped like a tenant resource with no matching policy is denied, not crashed" do
    tenant_id = "ws-authz-test-" <> Uniq.UUID.uuid4()
    stream_id = RiptideWeb.LDP.ResourceController.stream_id_for(tenant_id, ["doc"])

    {:ok, socket} = connect(Socket, %{})

    assert {:error, %{"reason" => "unauthorized"}} =
             subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{
               "after" => 0
             })
  end

  test "joining a topic shaped like a tenant resource with a public read policy succeeds" do
    tenant_id = "ws-authz-test-" <> Uniq.UUID.uuid4()
    stream_id = RiptideWeb.LDP.ResourceController.stream_id_for(tenant_id, ["doc"])
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    :ok =
      Riptide.Authz.Store.Placement.add_policy(tenant_id, [], %Riptide.Authz.Policy{
        effect: :allow,
        modes: [:read],
        matcher: :public
      })

    StreamSupervisor.ensure_ready(stream_id)

    {:ok, socket} = connect(Socket, %{})

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})
  end

  test "joining a topic not shaped like a tenant resource is denied, not crashed" do
    {:ok, socket} = connect(Socket, %{})

    assert {:error, %{"reason" => "unauthorized"}} =
             subscribe_and_join(socket, ReplicationChannel, "replication:some-legacy-stream-id", %{
               "after" => 0
             })
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/realtime/replication_channel_test.exs --trace`
Expected: FAIL — `ReplicationChannel.join/3` doesn't check authorization yet.

- [ ] **Step 3: Wire authorization into `ReplicationChannel.join/3`**

Replace the full contents of `lib/riptide_web/realtime/replication_channel.ex`:

```elixir
defmodule RiptideWeb.Realtime.ReplicationChannel do
  @moduledoc """
  WebSocket replication transport for StreamLD's `binding-websocket` — joins
  `"replication:<stream_id>"` with an `"after"` cursor, replies with a backlog,
  and pushes further events as `"replication_frame"` messages. Mirrors the SSE
  controller's cursor/gap semantics over Phoenix Channels instead of SSE.

  Authorization (Phase 4c) recovers the joining topic's tenant/path via
  `RiptideWeb.LDP.ResourceController.parse_stream_id/1` and checks it against
  `socket.assigns.current_subject` (established once at `connect/3` time,
  per Phase 4b) — a channel `join/3` never re-verifies *identity*, but it
  does check *authorization* per topic, since one socket can join many
  different topics over its lifetime and each may have different policies.
  """
  use Phoenix.Channel

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  @impl true
  def join("replication:" <> stream_id, %{"after" => cursor}, socket) do
    with {:ok, tenant_id, path_segments} <- ResourceController.parse_stream_id(stream_id),
         :allow <- Riptide.Authz.evaluate(tenant_id, path_segments, socket.assigns.current_subject, :read) do
      do_join(stream_id, cursor, socket)
    else
      _ -> {:error, %{"reason" => "unauthorized"}}
    end
  end

  defp do_join(stream_id, cursor, socket) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

        case StreamServer.get_since(stream_id, cursor) do
          {:gap, oldest} ->
            {:error, %{"oldestAvailable" => oldest}}

          {:ok, events} ->
            socket = assign(socket, :stream_id, stream_id)
            {:ok, %{"backlog" => Enum.map(events, &frame/1)}, socket}
        end

      :error ->
        {:error, %{"reason" => "service_unavailable"}}
    end
  end

  @impl true
  def handle_info({:new_event, %Event{} = event}, socket) do
    push(socket, "replication_frame", frame(event))
    {:noreply, socket}
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

  defp frame(%Event{} = event) do
    {:ok, turtle} = TurtleCodec.encode(Event.wire_payload(event))

    %{
      "cursor" => event.sequence,
      "event" => %{
        "sequence" => event.sequence,
        "streamId" => event.stream_id,
        "isSnapshot" => Event.wire_snapshot?(event),
        "payload" => turtle
      }
    }
  end
end
```

Note the existing pre-Phase-4c tests in this file (`joining with after: 0 receives no backlog`,
etc.) use plain `unique_stream_id()`-generated ids (e.g. `"ws-test-..."`) that are **not**
tenant-resource-shaped (`parse_stream_id/1` will return `:error` for them) — after this change
they would now be denied instead of succeeding. Update `unique_stream_id/0` (or add a new helper)
in this test file to build tenant-resource-shaped stream ids via
`RiptideWeb.LDP.ResourceController.stream_id_for/2`, and seed a `:public`, `[:read]` policy for
each generated tenant, the same way Task 7 handled this for the SSE test file — so those
pre-existing tests keep exercising streaming/backlog behavior, not authorization, unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide_web/realtime/replication_channel_test.exs --trace`
Expected: PASS, all tests.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide_web/realtime/replication_channel.ex test/riptide_web/realtime/replication_channel_test.exs
git commit -m "Add WebSocket authorization via Riptide.Authz.evaluate/4"
```

---

### Task 9: Policy management API

**Files:**
- Create: `lib/riptide_web/authz/policy_controller.ex`
- Modify: `lib/riptide_web/router.ex`
- Test: `test/riptide_web/authz/policy_controller_test.exs`

**Interfaces:**
- Consumes: `Riptide.Authz.Policy`/`Store` (Task 2), the `:tenant`/`:auth`/`:authz` pipeline
  (Task 5).
- Produces: `POST`/`GET /tenants/:tenant_id/policies`. No other task depends on this one — terminal
  feature task.

- [ ] **Step 1: Write the failing tests**

Create `test/riptide_web/authz/policy_controller_test.exs`:

```elixir
defmodule RiptideWeb.Authz.PolicyControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify("other-token"), do: {:ok, %{"sub" => "someone-else"}}
    def verify("friend-token"), do: {:ok, %{"sub" => "friend-1"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:riptide, :auth_verifier)
    Application.put_env(:riptide, :auth_verifier, StubVerifier)
    on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original) end)
    :ok
  end

  defp claim_tenant(tenant_id) do
    :claimed = Riptide.Authz.Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")
  end

  test "the owner can add a policy and then list it back" do
    tenant_id = "policy-api-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body =
      Jason.encode!(%{
        "effect" => "allow",
        "modes" => ["read"],
        "matcher" => "public"
      })

    post_conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert post_conn.status == 201

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/policies")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200

    [owner_policy, added_policy] = Jason.decode!(get_conn.resp_body)
    assert owner_policy["matcher"] == %{"agent" => "the-owner"}
    assert added_policy == %{"effect" => "allow", "modes" => ["read"], "matcher" => "public"}
  end

  test "a non-owner cannot add or list policies for someone else's tenant" do
    tenant_id = "policy-api-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body = Jason.encode!(%{"effect" => "allow", "modes" => ["read"], "matcher" => "public"})

    post_conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer other-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert post_conn.status == 403

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/policies")
      |> put_req_header("authorization", "Bearer other-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 403
  end

  test "adding a policy with an unrecognized effect returns 400" do
    tenant_id = "policy-api-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body = Jason.encode!(%{"effect" => "maybe", "modes" => ["read"], "matcher" => "public"})

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 400
  end

  test "an agent matcher round-trips as a nested map" do
    tenant_id = "policy-api-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body =
      Jason.encode!(%{
        "effect" => "allow",
        "modes" => ["read", "write"],
        "matcher" => %{"agent" => "friend-1"}
      })

    :post
    |> conn("/tenants/#{tenant_id}/policies", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer owner-token")
    |> RiptideWeb.Endpoint.call(@opts)

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/policies")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    [_owner_policy, added_policy] = Jason.decode!(get_conn.resp_body)
    assert added_policy["matcher"] == %{"agent" => "friend-1"}
    assert added_policy["modes"] == ["read", "write"]
  end

  # This is the capstone scenario the whole design's matcher expressiveness
  # exists for (see the Phase 4c design spec §1/§8): an owner shares access
  # with a specific, previously-unenumerated agent, and that agent's access
  # actually works against a real LDP resource afterward — not just that the
  # policy API itself accepts and echoes back the grant.
  test "a policy granted through this API actually enables that agent's real resource access" do
    tenant_id = "policy-api-e2e-" <> Uniq.UUID.uuid4()
    resource_path = "/tenants/#{tenant_id}/resources/shared-doc"
    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(
        RiptideWeb.LDP.ResourceController.stream_id_for(tenant_id, ["shared-doc"])
      )
    end)

    claim_tenant(tenant_id)

    friend_get_before_grant =
      :get
      |> conn(resource_path)
      |> put_req_header("authorization", "Bearer friend-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert friend_get_before_grant.status == 403

    :put
    |> conn(resource_path, "<https://pod.example/x> <https://pod.example/y> \"shared\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> put_req_header("authorization", "Bearer owner-token")
    |> RiptideWeb.Endpoint.call(@opts)

    grant_body =
      Jason.encode!(%{
        "effect" => "allow",
        "modes" => ["read"],
        "matcher" => %{"agent" => "friend-1"}
      })

    grant_conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", grant_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert grant_conn.status == 201

    friend_get_after_grant =
      :get
      |> conn(resource_path)
      |> put_req_header("authorization", "Bearer friend-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert friend_get_after_grant.status == 200
    assert friend_get_after_grant.resp_body =~ "\"shared\""

    friend_put_still_denied =
      :put
      |> conn(resource_path, "<https://pod.example/x> <https://pod.example/y> \"overwritten\" .\n")
      |> put_req_header("content-type", "text/turtle")
      |> put_req_header("authorization", "Bearer friend-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert friend_put_still_denied.status == 403
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/authz/policy_controller_test.exs --trace`
Expected: FAIL — no route matches `/tenants/:tenant_id/policies` yet.

- [ ] **Step 3: Implement the controller**

Create `lib/riptide_web/authz/policy_controller.ex`:

```elixir
defmodule RiptideWeb.Authz.PolicyController do
  @moduledoc """
  Minimal policy management API — `POST`/`GET /tenants/:tenant_id/policies`,
  scoped to tenant-root policies only (see the Phase 4c design spec §8).
  Gated by the same `:tenant`/`:auth`/`:authz` pipeline as the LDP resource
  routes: `Authorize` maps `POST` to `:write` and `GET` to `:read`, with
  `path_segments` defaulting to `[]` (the tenant root) since these routes
  have no `*path` glob — the same permission the bootstrap owner already
  holds is what's required to manage policies here, since this phase has no
  separate `Control` mode.
  """
  use Phoenix.Controller

  alias Riptide.Authz.Policy

  def create(conn, params) do
    tenant_id = conn.assigns.tenant_id
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)

    case policy_from_params(params) do
      {:ok, policy} ->
        :ok = store.add_policy(tenant_id, [], policy)
        send_resp(conn, 201, "")

      :error ->
        send_resp(conn, 400, "")
    end
  end

  def index(conn, _params) do
    tenant_id = conn.assigns.tenant_id
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)
    policies = store.list_policies(tenant_id, [])

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Enum.map(policies, &policy_to_map/1)))
  end

  defp policy_from_params(%{"effect" => effect, "modes" => modes, "matcher" => matcher})
       when is_list(modes) do
    with {:ok, effect} <- parse_effect(effect),
         {:ok, modes} <- parse_modes(modes),
         {:ok, matcher} <- parse_matcher(matcher) do
      {:ok, %Policy{effect: effect, modes: modes, matcher: matcher}}
    end
  end

  defp policy_from_params(_params), do: :error

  defp parse_effect("allow"), do: {:ok, :allow}
  defp parse_effect("deny"), do: {:ok, :deny}
  defp parse_effect(_other), do: :error

  defp parse_modes(modes) do
    parsed = Enum.map(modes, &parse_mode/1)

    if Enum.all?(parsed, &(&1 != :error)) do
      {:ok, parsed}
    else
      :error
    end
  end

  defp parse_mode("read"), do: :read
  defp parse_mode("write"), do: :write
  defp parse_mode(_other), do: :error

  defp parse_matcher("public"), do: {:ok, :public}
  defp parse_matcher("authenticated"), do: {:ok, :authenticated}
  defp parse_matcher(%{"agent" => subject}) when is_binary(subject), do: {:ok, {:agent, subject}}
  defp parse_matcher(_other), do: :error

  defp policy_to_map(%Policy{effect: effect, modes: modes, matcher: matcher}) do
    %{
      "effect" => Atom.to_string(effect),
      "modes" => Enum.map(modes, &Atom.to_string/1),
      "matcher" => matcher_to_json(matcher)
    }
  end

  defp matcher_to_json(:public), do: "public"
  defp matcher_to_json(:authenticated), do: "authenticated"
  defp matcher_to_json({:agent, subject}), do: %{"agent" => subject}
end
```

- [ ] **Step 4: Wire the routes**

In `lib/riptide_web/router.ex`, add to the existing `scope "/tenants/:tenant_id"` block (which
already has `pipe_through [:api, :tenant, :auth, :authz]` from Task 5), after the 5 existing LDP
resource routes:

```elixir
    post "/policies", RiptideWeb.Authz.PolicyController, :create
    get "/policies", RiptideWeb.Authz.PolicyController, :index
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide_web/authz/policy_controller_test.exs --trace`
Expected: PASS, all 5 tests.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 7: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 8: Commit**

```bash
git add lib/riptide_web/authz/policy_controller.ex lib/riptide_web/router.ex \
        test/riptide_web/authz/policy_controller_test.exs
git commit -m "Add minimal tenant-root policy management API"
```

---

### Task 10: Full verification + `PROGRESS.md` + wrap-up

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: everything from Tasks 1-9.
- Produces: nothing further downstream — terminal task.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 2: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 3: Update the `## 4. Security & multi-tenancy` section of `PROGRESS.md`**

In `PROGRESS.md`, find the `**Phasing:**` list under `## 4. Security & multi-tenancy — decomposed
into phases` and replace the `Phase 4c` line:

```markdown
- **Phase 4c — Authorization (ACP).** Not yet designed.
```

with:

```markdown
- **Phase 4c — Authorization (ACP).** **Shipped 2026-08-26** — see
  `docs/superpowers/specs/2026-08-26-phase-4c-authorization-design.md`. An ACP-inspired policy
  model (`Riptide.Authz.Policy`: `effect: :allow | :deny`, `modes: [:read | :write]`, `matcher:
  :public | :authenticated | {:agent, subject}`), evaluated with container-level inheritance and
  deny-overrides-allow, enforced across all 3 transports (a new `RiptideWeb.Plugs.Authorize` for
  LDP HTTP; direct `Riptide.Authz.evaluate/4` calls from SSE and the WebSocket channel after
  recovering tenant/path from an opaque `stream_id` via a new `parse_stream_id/1`). Default-deny,
  with an implicit bootstrap: the first authenticated write to a policy-less tenant atomically
  claims tenant-root ownership (`Riptide.Authz.Store.claim_tenant_if_unclaimed/2`), so no separate
  tenant registry is needed. Policies persist via the *existing* shared placement Ra cluster
  (`Riptide.Placement.PlacementMachine` gained `policies` state alongside its original `streams`
  state) rather than a second Ra cluster to operate. A minimal, tenant-root-only policy management
  API (`POST`/`GET /tenants/:tenant_id/policies`) lets an owner grant other agents access. Not
  full Solid ACP compliance — no Access Control Resources as discoverable resources, no
  client/VC/issuer matchers, no `Control` mode, no policy revocation yet; see the design spec §3
  for the complete list of deliberate omissions.
```

And update the trailing `**Status**:` line:

```markdown
**Status**: Phases 4a-4c shipped 2026-08-26. Phase 4d not yet designed.
```

- [ ] **Step 4: Commit**

```bash
git add PROGRESS.md
git commit -m "Mark Phase 4c shipped in PROGRESS.md"
```
