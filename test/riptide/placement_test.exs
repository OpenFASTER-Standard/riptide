defmodule Riptide.PlacementTest do
  # async: false — the "emits an exception event when every member fails"
  # test below sets :placement_members_override, global Application state
  # every other test touching Riptide.Placement anywhere in the suite also
  # reads, matching the same reasoning test/riptide_web/health_test.exs and
  # test/riptide_web/realtime/sse_controller_test.exs already use for the
  # identical hazard.
  use ExUnit.Case, async: false

  alias Riptide.Placement

  describe "select_nodes/2" do
    test "returns exactly `count` distinct nodes when enough candidates exist" do
      result = Placement.select_nodes([:a, :b, :c, :d, :e], 3)

      assert length(result) == 3
      assert Enum.uniq(result) == result
      assert Enum.all?(result, &(&1 in [:a, :b, :c, :d, :e]))
    end

    test "deduplicates candidate nodes before selecting" do
      result = Placement.select_nodes([:a, :a, :b, :b, :c], 3)
      assert Enum.sort(result) == [:a, :b, :c]
    end

    test "returns all candidates if fewer than `count` are available" do
      result = Placement.select_nodes([:a, :b], 3)
      assert Enum.sort(result) == [:a, :b]
    end
  end

  describe "propose_nodes/1" do
    test "always includes the local node, even alone" do
      # Node.list() is empty on a non-distributed test node, so with
      # replication_factor 1 the only possible candidate is node() itself.
      assert Placement.propose_nodes(1) == [node()]
    end

    test "always includes the local node first, even with other candidates and RF > 1" do
      result = Placement.propose_nodes(3, [:peer_a, :peer_b, :peer_c])

      assert hd(result) == node()
      assert length(result) == 3
      assert Enum.uniq(result) == result
    end

    test "never duplicates the local node if it's already present in the given peer list" do
      result = Placement.propose_nodes(3, [node(), :peer_a, :peer_b])

      assert result == [node() | Enum.sort(result -- [node()])] or
               Enum.sort(result) == Enum.sort([node(), :peer_a, :peer_b])

      assert Enum.uniq(result) == result
      assert hd(result) == node()
    end

    test "returns just the local node when replication_factor is 1, regardless of peers" do
      assert Placement.propose_nodes(1, [:peer_a, :peer_b]) == [node()]
    end
  end

  describe "assign/2 and lookup/2 against the real metadata cluster" do
    test "a real assignment round-trips through the real placement cluster, using default arguments" do
      stream_id = "placement-roundtrip-" <> Uniq.UUID.uuid4()
      assigned = Placement.assign(stream_id, [node()])

      assert assigned == [node()]
      assert Placement.lookup(stream_id) == [node()]
    end

    test "list_all/1 includes every real assignment made so far" do
      stream_id = "placement-list-all-" <> Uniq.UUID.uuid4()
      Placement.assign(stream_id, [node()])

      assert Placement.list_all()[stream_id] == [node()]
    end

    test "replace_member/3 swaps a dead node for a new one in a real assignment" do
      stream_id = "placement-replace-member-" <> Uniq.UUID.uuid4()
      fake_dead_node = :"fake-dead@nowhere"
      Placement.assign(stream_id, [node(), fake_dead_node])

      replaced = Placement.replace_member(stream_id, fake_dead_node, :"fake-new@nowhere")

      assert Enum.sort(replaced) == Enum.sort([node(), :"fake-new@nowhere"])
      assert Enum.sort(Placement.lookup(stream_id)) == Enum.sort([node(), :"fake-new@nowhere"])
    end

    test "replace_member/3 is a no-op if the dead node named is no longer part of the assignment" do
      stream_id = "placement-replace-member-noop-" <> Uniq.UUID.uuid4()
      Placement.assign(stream_id, [node()])

      result = Placement.replace_member(stream_id, :"never-was-here@nowhere", :new@nowhere)

      assert result == [node()]
      assert Placement.lookup(stream_id) == [node()]
    end
  end

  describe "claim_name/2 and lookup_name/1 against the real metadata cluster" do
    test "claim_name/2 claims a brand-new name exactly once" do
      name = "authz-claim-test-" <> Uniq.UUID.uuid4()

      assert Placement.claim_name(name, "tenant-1") == :claimed
      assert Placement.claim_name(name, "tenant-2") == :already_claimed
      assert Placement.lookup_name(name) == "tenant-1"
    end

    test "lookup_name/1 returns nil for a name that was never claimed" do
      assert Placement.lookup_name("authz-lookup-empty-" <> Uniq.UUID.uuid4()) == nil
    end

    test "claim_name/2 resolves a real race between two simultaneous claims to exactly one winner" do
      name = "authz-claim-race-test-" <> Uniq.UUID.uuid4()

      results =
        [
          Task.async(fn -> Placement.claim_name(name, "racer-1") end),
          Task.async(fn -> Placement.claim_name(name, "racer-2") end)
        ]
        |> Enum.map(&Task.await/1)

      assert Enum.sort(results) == [:already_claimed, :claimed]

      # Exactly one tenant_id is claimed for this name afterward, for
      # whichever racer's command Raft's log actually ordered first — never
      # both, never neither. Every command against this Ra cluster is
      # serialized through consensus, so this proves the race is resolved by
      # the log itself rather than by any check-then-act ordering on the
      # caller side.
      winner = Placement.lookup_name(name)
      assert winner in ["racer-1", "racer-2"]
    end
  end

  describe "telemetry instrumentation" do
    test "lookup/1 emits a riptide.placement.lookup telemetry span" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:riptide, :placement, :lookup, :stop]])

      Placement.lookup("some-nonexistent-stream-id")

      assert_received {[:riptide, :placement, :lookup, :stop], ^ref, %{duration: duration}, %{}}
      assert is_integer(duration)
    end

    test "lookup/1 emits an exception event when every member fails" do
      Riptide.AppEnvTestHelpers.put_env(:riptide, :placement_members_override, [
        :nonexistent@nohost
      ])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:riptide, :placement, :lookup, :exception]
        ])

      assert_raise RuntimeError, fn ->
        Placement.lookup("some-stream-id")
      end

      assert_received {[:riptide, :placement, :lookup, :exception], ^ref, %{duration: _},
                       %{kind: :error}}
    end

    test "assign/2 emits a riptide.placement.assign telemetry span" do
      stream_id = "telemetry-assign-test-" <> Uniq.UUID.uuid4()

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:riptide, :placement, :assign, :stop]])

      Placement.assign(stream_id, [node()])

      assert_received {[:riptide, :placement, :assign, :stop], ^ref, %{duration: duration}, %{}}
      assert is_integer(duration)
    end
  end
end
