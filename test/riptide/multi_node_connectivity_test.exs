defmodule Riptide.MultiNodeConnectivityTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  @peers [{:riptide0, "riptide-0"}, {:riptide1, "riptide-1"}, {:riptide2, "riptide-2"}]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"multi_node_connectivity_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "N real distributed Erlang nodes connect and stay connected, each with its own HOSTNAME-derived Ra data directory" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, hostname} <- @peers do
        {:ok, pid, node} =
          :peer.start_link(%{
            name: alive_name,
            host: ~c"127.0.0.1",
            longnames: true,
            args: pa_args,
            env: [{~c"HOSTNAME", to_charlist(hostname)}]
          })

        {pid, node, hostname}
      end

    # NEW GOTCHA (found empirically while implementing this test, beyond the
    # brief's list): by the time this `on_exit` callback runs, one or more
    # peer control processes are sometimes already gone — even though all
    # three were confirmed alive (`Process.alive?/1` true) at the very end of
    # the test body itself, with no failure or crash in between. ExUnit runs
    # `on_exit` callbacks in a separate process, spawned after the test
    # process itself has already finished; the peer control gen_server
    # returned by `:peer.start_link/1` is not proof against this — it
    # terminates on its own shortly after the linked test process exits, even
    # though that exit is `:normal` and the peer control process traps exits
    # (confirmed by inspecting `peer`'s own source: `handle_info` has no
    # clause that would keep it alive across an owner's exit signal of any
    # reason once boot has completed). A bare `:peer.stop(pid)` call here
    # then raises (`:noproc`, or a `:sys.terminate` reason mismatch against
    # the peer's actual `:shutdown` exit) depending on exactly how far the
    # peer got in tearing itself down before this callback ran — flaky in a
    # way that's about cleanup, not about anything this test is meant to
    # verify. `:peer.stop/1` is not idempotent against an already-dead
    # target, so guard the call instead of asserting it always succeeds.
    on_exit(fn ->
      Enum.each(peers, fn {pid, _node, _hostname} ->
        if Process.alive?(pid) do
          try do
            :peer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      # Each peer's Ra data directory (keyed on HOSTNAME, per the assertion
      # below) is real, on-disk state — @peers' hostnames ("riptide-0/1/2")
      # are reused by several other :peer-based test files, so leaving this
      # behind lets a later test collide with it.
      Enum.each(@peers, fn {_alive_name, hostname} ->
        File.rm_rf!(Path.join(File.cwd!(), hostname))
      end)
    end)

    nodes = Enum.map(peers, fn {_pid, node, _hostname} -> node end)

    # Peers don't auto-connect to each other — connect every pair explicitly,
    # mirroring what libcluster's discovery strategy does in production.
    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    # Real connectivity, not just a one-shot connect: poll several times.
    for _ <- 1..5 do
      for {_pid, node, _hostname} <- peers do
        seen = node |> then(&:erpc.call(&1, Node, :list, [])) |> MapSet.new()
        expected = nodes |> List.delete(node) |> MapSet.new()
        assert MapSet.subset?(expected, seen)
      end

      Process.sleep(100)
    end

    # :ra's data-directory decoupling (Task 1) holds under real distributed node
    # identities: each peer's own Ra system uses its own HOSTNAME-derived
    # directory, isolated from the others' — even though all three are now real,
    # independently-addressable Erlang nodes rather than one test process.
    stream_id = "multi-node-test-" <> Uniq.UUID.uuid4()

    for {_pid, node, hostname} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])

      :erpc.call(node, Riptide.RaCluster, :start_or_restart, [
        stream_id,
        {:module, Riptide.Test.EchoMachine, %{}}
      ])

      config = :erpc.call(node, :ra_system, :fetch, [:default])

      assert Path.basename(config.data_dir) == hostname
      assert Path.basename(config.wal_data_dir) == hostname
    end
  end

  defp unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end
end
