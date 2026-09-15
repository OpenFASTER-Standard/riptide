defmodule Riptide.Decade.ChaosTest do
  use ExUnit.Case, async: false

  alias Riptide.Decade.Chaos

  @moduletag timeout: 60_000

  # A 4th, deliberately-unassigned "spare" peer is required, not optional:
  # `ReplicaHealer.pick_replacement/2` only ever picks a live fleet node
  # NOT already among a stream's current members — with only 3 total nodes
  # and all 3 already assigned to the stream, there is no candidate to
  # promote and a "repair" silently no-ops (`do_claimed_repair`'s `nil ->
  # :ok` branch). This exactly mirrors `replica_healer_leadership_gate_test.exs`'s
  # own `@replacement` peer for the identical reason.
  @peers [
    {:chaos_a, "chaos-riptide-0", ~c"127.0.0.80"},
    {:chaos_b, "chaos-riptide-1", ~c"127.0.0.81"},
    {:chaos_c, "chaos-riptide-2", ~c"127.0.0.82"}
  ]
  @spare {:chaos_spare, "chaos-riptide-spare", ~c"127.0.0.83"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"decade_chaos_test_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a killed replica is detected and repaired by the real ReplicaHealer sweep path" do
    all_specs = @peers ++ [@spare]
    peers = Chaos.start_cluster(all_specs)
    on_exit(fn -> Chaos.stop_cluster(peers, all_specs) end)

    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _}, {_pid_spare, _node_spare, _}] =
      peers

    original_nodes = [node_a, node_b, node_c]

    stream_id = "decade-chaos-" <> Uniq.UUID.uuid4()

    assert Enum.sort(:erpc.call(node_a, Riptide.Placement, :assign, [stream_id, original_nodes])) ==
             Enum.sort(original_nodes)

    assert :ok = :erpc.call(node_a, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])

    Chaos.kill_node(peers, node_c)

    leader_node = Chaos.await_leader([node_a, node_b])
    assert leader_node != nil

    :erpc.call(leader_node, :erlang, :send, [Riptide.Stream.ReplicaHealer, :sweep])
    :erpc.call(leader_node, :sys, :get_state, [Riptide.Stream.ReplicaHealer, 30_000])

    repaired_nodes = :erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])
    assert length(repaired_nodes) == 3
    refute node_c in repaired_nodes
  end
end
