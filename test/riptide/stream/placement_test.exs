defmodule Riptide.Stream.PlacementTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement
  alias Riptide.RaCluster
  alias Riptide.Stream.Placement, as: StreamPlacement
  alias Riptide.Stream.RaMachine
  alias Riptide.Test.EchoMachine

  describe "ensure_started/4" do
    test "a genuinely new stream gets real placement and forms a real cluster" do
      stream_id = "stream-placement-new-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)

      assert {:ok, server_ids} =
               StreamPlacement.ensure_started(stream_id, {:module, EchoMachine, %{}})

      # Node.list() is empty in this single-node test env, so RF=3 collapses
      # to just the local node — same degradation `Placement.propose_nodes/2`
      # already guarantees.
      assert server_ids == [{String.to_atom(RaCluster.uid_for(stream_id)), node()}]
      assert Placement.lookup(stream_id) == [node()]
    end

    test "a stream already cached is returned without calling the formation function again" do
      stream_id = "stream-placement-cache-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      machine = {:module, EchoMachine, %{}}

      {:ok, server_ids} = StreamPlacement.ensure_started(stream_id, machine)

      unreachable_formation_fun = fn _uid, _nodes, _machine -> raise "should never be called" end

      assert {:ok, ^server_ids} =
               StreamPlacement.ensure_started(stream_id, machine, unreachable_formation_fun)
    end

    test "a stream with real pre-existing on-disk data backfills to its own node, not a fresh proposal" do
      stream_id = "stream-placement-backfill-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      machine = {:module, RaMachine, %{retention: :infinity}}

      # Simulate a pre-3c-ii stream: real on-disk data, created by calling
      # RaCluster directly, bypassing Riptide.Stream.Placement entirely — so
      # there's real data on disk but no Placement entry for it at all.
      RaCluster.start_or_restart(stream_id, machine)
      assert Placement.lookup(stream_id) == nil

      assert {:ok, server_ids} = StreamPlacement.ensure_started(stream_id, machine)
      assert server_ids == [{String.to_atom(RaCluster.uid_for(stream_id)), node()}]
      assert Placement.lookup(stream_id) == [node()]
    end

    test "bounded retry: succeeds once the formation function stops failing" do
      stream_id = "stream-placement-retry-ok-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      real_formation_fun = &RaCluster.start_or_join_replicated/3

      formation_fun = fn uid, nodes, machine ->
        count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if count < 2,
          do: {:error, :cluster_not_formed},
          else: real_formation_fun.(uid, nodes, machine)
      end

      assert {:ok, _server_ids} =
               StreamPlacement.ensure_started(
                 stream_id,
                 {:module, EchoMachine, %{}},
                 formation_fun,
                 fn _ms -> :ok end
               )

      assert Agent.get(counter, & &1) == 3
    end

    test "bounded retry: gives up and returns an error after 3 failed attempts" do
      stream_id = "stream-placement-retry-fail-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      formation_fun = fn _uid, _nodes, _machine ->
        Agent.update(counter, &(&1 + 1))
        {:error, :cluster_not_formed}
      end

      assert StreamPlacement.ensure_started(
               stream_id,
               {:module, EchoMachine, %{}},
               formation_fun,
               fn _ms -> :ok end
             ) == {:error, :cluster_not_formed}

      assert Agent.get(counter, & &1) == 3
    end

    test "a stream already assigned to nodes not including this one skips formation entirely" do
      stream_id = "stream-placement-remote-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      remote_node = :"other-node@nowhere"

      assert Placement.assign(stream_id, [remote_node]) == [remote_node]

      unreachable_formation_fun = fn _uid, _nodes, _machine -> raise "should never be called" end

      assert {:ok, server_ids} =
               StreamPlacement.ensure_started(
                 stream_id,
                 {:module, EchoMachine, %{}},
                 unreachable_formation_fun
               )

      uid = RaCluster.uid_for(stream_id)
      assert server_ids == [{String.to_atom(uid), remote_node}]
    end

    test "a stream already assigned to nodes including this one re-forms/rejoins for real" do
      stream_id = "stream-placement-rejoin-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      machine = {:module, EchoMachine, %{}}

      assert Placement.assign(stream_id, [node()]) == [node()]

      assert {:ok, server_ids} = StreamPlacement.ensure_started(stream_id, machine)
      uid = RaCluster.uid_for(stream_id)
      assert server_ids == [{String.to_atom(uid), node()}]

      pid = Process.whereis(String.to_atom(uid))
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "server_ids!/1" do
    test "raises if ensure_started/2 has never run for this stream on this node" do
      stream_id = "stream-placement-unstarted-" <> Uniq.UUID.uuid4()

      assert_raise RuntimeError, ~r/before ensure_started\/2 ever ran/, fn ->
        StreamPlacement.server_ids!(stream_id)
      end
    end

    test "returns the cached server_ids after ensure_started/2 has run" do
      stream_id = "stream-placement-started-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)

      {:ok, server_ids} = StreamPlacement.ensure_started(stream_id, {:module, EchoMachine, %{}})
      assert StreamPlacement.server_ids!(stream_id) == server_ids
    end
  end
end
