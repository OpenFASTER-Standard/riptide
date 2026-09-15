defmodule Riptide.Decade.SimulationTest do
  use ExUnit.Case, async: false

  alias Riptide.Decade.{Chaos, VolumeSeed}

  @moduletag :decade_simulation
  @moduletag timeout: :infinity

  @peers [
    {:decade_a, "decade-riptide-0", ~c"127.0.0.90"},
    {:decade_b, "decade-riptide-1", ~c"127.0.0.91"},
    {:decade_c, "decade-riptide-2", ~c"127.0.0.92"}
  ]

  # Two spares, not one: each real repair (see Task 6's own note on this)
  # consumes exactly one live non-member node as its replacement, so
  # driving two full kill+repair rounds — proving the healer keeps working
  # across *repeated* chaos, not just once — needs two. A third round would
  # need a third spare; two is enough to prove the mechanism repeats.
  @spares [
    {:decade_spare_1, "decade-riptide-spare-1", ~c"127.0.0.93"},
    {:decade_spare_2, "decade-riptide-spare-2", ~c"127.0.0.94"}
  ]

  # Compressed stand-in for a literal decade of volume (10 * 365 * 24 * 12 =
  # 1,051,200 writes at one every 5 minutes), NOT the real decade-scale
  # count — that's already covered, at true scale, by
  # `volume_seed_test.exs`'s own regression test (`:benchmark`-tagged,
  # reviewed, passing). Task 7's own job is proving composition (volume +
  # virtual clock + chaos all running together), not re-proving raw scale a
  # second time; the literal count here would make an already-long,
  # explicitly on-demand test (run 3x to check for flakiness, per Task 7's
  # own instructions) take 40+ minutes per run for no additional coverage.
  # 5,000 events is still real Ra consensus through the same latency-sample
  # code path `volume_seed_test.exs` exercises, just at a duration that
  # keeps this umbrella scenario actually runnable on demand.
  @decade_event_count 5_000
  @seconds_per_chaos_round 86_400 * 180

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"decade_simulation_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a decade of usage: volume, diverse operations, and chaos, all at once" do
    {:ok, _clock} = start_supervised({Riptide.Clock.Virtual, System.system_time(:second)})
    Riptide.AppEnvTestHelpers.put_env(:riptide, :clock, Riptide.Clock.Virtual)

    all_specs = @peers ++ @spares
    peers = Chaos.start_cluster(all_specs)
    on_exit(fn -> Chaos.stop_cluster(peers, all_specs) end)

    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _} | _spares] = peers
    original_nodes = [node_a, node_b, node_c]

    # Phase 1: fast-forward a hot stream to decade-scale volume, directly
    # on the real local (origin) app instance test_helper.exs already
    # booted — this is the same regression guard as volume_seed_test.exs,
    # kept here so a real degrading trend fails the umbrella scenario too.
    hot_stream_id = "decade-hot-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(hot_stream_id) end)
    seed_result = VolumeSeed.seed_stream(hot_stream_id, @decade_event_count)

    first_avg = seed_result.latencies_us |> Enum.take(3) |> Enum.sum() |> Kernel./(3)
    last_avg = seed_result.latencies_us |> Enum.take(-3) |> Enum.sum() |> Kernel./(3)
    assert last_avg / first_avg < 3

    # Phase 2: diverse operations against the multi-node chaos cluster,
    # interleaved with node kills, real repairs, and virtual-clock jumps.
    remote_stream_id = "decade-remote-" <> Uniq.UUID.uuid4()

    assert Enum.sort(
             :erpc.call(node_a, Riptide.Placement, :assign, [remote_stream_id, original_nodes])
           ) ==
             Enum.sort(original_nodes)

    assert :ok =
             :erpc.call(node_a, Riptide.Stream.StreamSupervisor, :ensure_ready, [remote_stream_id])

    Enum.reduce(1..2, original_nodes, fn round, current_members ->
      graph = :erpc.call(node_a, RDF.Graph, :new, [])
      event = :erpc.call(node_a, Riptide.Event, :new, [remote_stream_id, :replace, graph])

      stamped =
        :erpc.call(node_a, Riptide.Stream.StreamServer, :append, [remote_stream_id, event])

      assert stamped.sequence == round

      Riptide.Clock.Virtual.advance(@seconds_per_chaos_round)

      target = safe_kill_target(current_members, original_nodes, node_a)
      assert target != nil, "no kill target available without breaking placement quorum"
      Chaos.kill_node(peers, target)

      survivors = current_members -- [target]
      leader = Chaos.await_leader(survivors)
      assert leader != nil, "no survivor became placement leader after killing #{inspect(target)}"

      :erpc.call(leader, :erlang, :send, [Riptide.Stream.ReplicaHealer, :sweep])
      :erpc.call(leader, :sys, :get_state, [Riptide.Stream.ReplicaHealer, 30_000])

      repaired = :erpc.call(node_a, Riptide.Placement, :lookup, [remote_stream_id])
      assert length(repaired) == 3
      refute target in repaired

      repaired
    end)

    {:ok, final_events} =
      :erpc.call(node_a, Riptide.Stream.StreamServer, :get_since, [remote_stream_id, 0])

    assert length(final_events) == 2
  end

  # PlacementMachine's own Ra consensus cluster is fixed at genesis to
  # exactly the 3 core peers (`original_nodes` here) — spares are never
  # voting members of it (see Task 6's own `Enum.take(peers, 3)` fix) — so
  # its raft quorum needs >= 2 of *those three specifically* to stay alive
  # at all times, no matter which physical nodes currently host the
  # stream's own replica list at a given moment. This deliberately does
  # NOT rely on `PlacementMachine.replace_in_list/3` substituting a
  # repaired-in spare at the dead member's old list position (an
  # implementation detail this test shouldn't depend on) — it explicitly
  # computes, for each killable candidate, how many of the 3 genesis
  # peers would remain alive afterward, and only picks one that keeps
  # that count >= 2. `node_a` is never a candidate since it keeps
  # orchestrating via :erpc from the origin for the rest of the test.
  defp safe_kill_target(current_members, original_nodes, node_a) do
    Enum.find(current_members, fn candidate ->
      candidate != node_a and
        current_members
        |> Enum.filter(&(&1 in original_nodes))
        |> List.delete(candidate)
        |> length() >= 2
    end)
  end
end
