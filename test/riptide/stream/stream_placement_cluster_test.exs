defmodule Riptide.Stream.StreamPlacementClusterTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 60_000

  @new_stream_peers [
    {:riptide_stream0, "riptide-0", ~c"127.0.0.4"},
    {:riptide_stream1, "riptide-1", ~c"127.0.0.5"},
    {:riptide_stream2, "riptide-2", ~c"127.0.0.6"}
  ]

  @backfill_peers [
    {:riptide_backfill0, "riptide-0", ~c"127.0.0.7"},
    {:riptide_backfill1, "riptide-1", ~c"127.0.0.8"},
    {:riptide_backfill2, "riptide-2", ~c"127.0.0.9"}
  ]

  # NOTE: unlike `placement_cluster_test.exs`/`multi_node_connectivity_test.exs`,
  # this `setup_all` doesn't need to worry about this test process's own
  # node being hidden or not — see the "NEW GOTCHA" comment on peer spawning
  # in `start_and_bootstrap_peers/1` below for why, and for the real fix to
  # the problem an earlier version of this comment described here.
  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"stream_placement_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a genuinely new stream forms a real 3-member cluster across 3 real nodes and replicates writes" do
    {peers, nodes} = start_and_bootstrap_peers(@new_stream_peers)

    on_exit(fn -> stop_peers_and_cleanup(peers, @new_stream_peers) end)

    {_pid, entry_node, _ordinal} = hd(peers)
    stream_id = "stream-placement-cluster-" <> Uniq.UUID.uuid4()

    # Goes through the real StreamServer entry point (not RaCluster/
    # Riptide.Stream.Placement directly) — this is the proof that Task 5's
    # integration, not just the lower-level formation mechanics, works
    # against real distinct nodes. Placement.propose_nodes/2's candidate
    # list is Node.list() ++ [node()] — on a real :peer node this correctly
    # sees its two connected siblings, so a genuinely new stream with RF=3
    # and exactly 3 connected peers gets all 3, deterministically (no
    # randomness needed to reach "take 3 of 3").
    assert {:ok, _pid} =
             :erpc.call(entry_node, Riptide.Stream.StreamServer, :start_link, [stream_id])

    server_ids = :erpc.call(entry_node, Riptide.Stream.Placement, :server_ids!, [stream_id])
    assert length(server_ids) == 3
    assigned_nodes = Enum.map(server_ids, fn {_name, node} -> node end)
    assert Enum.sort(assigned_nodes) == Enum.sort(nodes)

    graph = :erpc.call(entry_node, RDF.Graph, :new, [])
    event = :erpc.call(entry_node, Riptide.Event, :new, [stream_id, :replace, graph])

    stamped = :erpc.call(entry_node, Riptide.Stream.StreamServer, :append, [stream_id, event])
    assert stamped.sequence == 1

    # Read from a *different* peer than the one that wrote — proving real
    # Raft replication through the stream's own multi-member cluster, not
    # local memory. That peer is a legitimate member (one of the 3 assigned
    # nodes), so its own StreamServer.start_link/1 call rediscovers the
    # already-running local member via the self-correcting recheck in
    # RaCluster.start_or_join_replicated/3 (Task 2), not a fresh formation.
    {_pid, reader_node, _ordinal} = Enum.at(peers, 1)

    assert {:ok, _pid} =
             :erpc.call(reader_node, Riptide.Stream.StreamServer, :start_link, [stream_id])

    assert {:ok, [%{sequence: 1}]} =
             :erpc.call(reader_node, Riptide.Stream.StreamServer, :get_since, [stream_id, 0])
  end

  test "a stream with real pre-existing on-disk data on one node backfills to that node alone" do
    {peers, _nodes} = start_and_bootstrap_peers(@backfill_peers)

    on_exit(fn -> stop_peers_and_cleanup(peers, @backfill_peers) end)

    {_pid, origin_node, _ordinal} = hd(peers)
    stream_id = "stream-placement-backfill-" <> Uniq.UUID.uuid4()
    machine = {:module, Riptide.Stream.RaMachine, %{retention: :infinity}}

    # Bypass Riptide.Stream.Placement/StreamServer entirely to create real
    # on-disk data on exactly one node — simulating a stream that already
    # existed before this phase shipped, before any Placement entry for it
    # ever existed.
    :erpc.call(origin_node, Riptide.RaCluster, :start_or_restart, [stream_id, machine])

    assert :erpc.call(origin_node, Riptide.Placement, :lookup, [stream_id]) == nil

    # Goes through the real StreamServer entry point, same as the other
    # test above, so this proves the backfill path end-to-end through
    # Task 5's integration too, not just Riptide.Stream.Placement in
    # isolation.
    assert {:ok, _pid} =
             :erpc.call(origin_node, Riptide.Stream.StreamServer, :start_link, [stream_id])

    server_ids = :erpc.call(origin_node, Riptide.Stream.Placement, :server_ids!, [stream_id])
    uid = :erpc.call(origin_node, Riptide.RaCluster, :uid_for, [stream_id])
    assert server_ids == [{String.to_atom(uid), origin_node}]

    assert :erpc.call(origin_node, Riptide.Placement, :lookup, [stream_id]) == [origin_node]
  end

  # Spawns the given peers, connects them, pre-starts each one's local :ra
  # system, bootstraps the real placement metadata cluster across them, and
  # starts Riptide.Stream.Placement's ETS-owning GenServer on each — the
  # same sequential-pass ordering placement_cluster_test.exs (Phase 3c-i)
  # already proved necessary (:ra must be started as an OTP app on every
  # member before any of them attempts cluster formation, since
  # attempt_start_placement_cluster/1 (now start_genesis_placement_cluster/1) reaches out to the *other* members
  # over RPC too, not just the local one).
  defp start_and_bootstrap_peers(peer_specs) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers = spawn_peers(peer_specs, pa_args)

    push_test_module_to_peers(peers)

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    connect_peers(nodes)
    start_ra_application(peers)
    start_ra_systems(peers)
    bootstrap_placement_cluster(peers, nodes)
    start_pubsub(peers)
    start_placement_server(peers)

    {peers, nodes}
  end

  # NEW GOTCHA (found empirically while implementing this test, beyond the
  # brief's own list — the deepest and most surprising one): the brief's
  # own draft spawned peers the same way `placement_cluster_test.exs`
  # does — `:peer.start_link(%{name: ..., host: ..., longnames: true,
  # ...})`. Passing `name:` (+ an alive origin) makes `:peer` boot the
  # child as a real distributed node AND — confirmed empirically, and not
  # documented anywhere obvious — immediately connect it back to this
  # (the origin/controller) node as a perfectly ordinary, *non-hidden*
  # connection, before `:peer.start_link/1` even returns. From
  # `Node.list()`'s perspective on the peer, that auto-connection is
  # indistinguishable from a real sibling stream node.
  # `placement_cluster_test.exs` never notices because it always builds
  # its own explicit node list rather than trusting `Node.list()`; this
  # test can't avoid the exposure, because `Placement.propose_nodes/2` —
  # real production code, exercised here through `StreamServer.start_link/1`,
  # not bypassed — itself computes its candidate set from `Node.list() ++
  # [node()]` on whichever peer calls it. With the origin visible, a
  # genuinely-3-peer stream cluster could non-deterministically get the
  # origin node as a 3rd member instead of the real 3rd peer, failing
  # this test's `assert Enum.sort(assigned_nodes) == Enum.sort(nodes)` —
  # and this isn't just a test-assertion problem: `Riptide.RaCluster`
  # would genuinely try to form part of the stream's real Ra cluster on
  # the origin node too, an actually-wrong outcome, not a cosmetic one.
  #
  # First fix attempt — making *this test's own* origin node hidden via
  # `:net_kernel.start/2`'s `hidden: true` (`Node.start/2,3` doesn't
  # expose it) — closed the immediate assertion failure but broke much
  # more: `test/test_helper.exs` calls
  # `Riptide.RaCluster.attempt_start_placement_cluster/0` (now `start_genesis_placement_cluster/1`) once at suite
  # boot, before *any* test's `setup_all` runs and before anything makes
  # this BEAM distributed, so that shared, collapsed placement cluster's
  # Ra server ends up permanently registered under `{:riptide_placement,
  # :nonode@nohost}`. Changing `node()` for the rest of the suite (which
  # is what starting — or worse, restarting — distribution here does)
  # does NOT retroactively re-register that already-running Ra server;
  # it's simply orphaned, since `{Name, Node}` Erlang process addressing
  # requires the CURRENT node identity to match. Confirmed via a broad
  # `mix test` run: every other test reaching
  # `Riptide.Stream.Placement`/`Riptide.Placement` afterwards started
  # failing with `Ra consistent query failed for {:riptide_placement,
  # :nonode@nohost}: :noproc`. Also confirmed this exact failure mode is
  # pre-existing and NOT specific to this file — it reproduces with this
  # file removed entirely, from `placement_cluster_test.exs` or
  # `multi_node_connectivity_test.exs` alone (either one calling plain
  # `Node.start/2` already changes `node()` permanently for the rest of
  # the suite). So no amount of care in *this* test's own `setup_all`
  # about being hidden or not can fully close the gap on its own: if
  # THIS module's `setup_all` happens to run after one of those two
  # already left a non-hidden origin alive (real, observed: seed-
  # dependent `mix test` ordering across all three async: false
  # `:peer`-based files), this test's own peers would still see that
  # non-hidden origin in `Node.list()` — reproduced concretely once, with
  # `assigned_nodes` containing `multi_node_connectivity_origin@...`
  # instead of the real 3rd peer.
  #
  # Real fix, entirely within this test, not touching the other two
  # files or `test_helper.exs`: don't let `:peer` establish the
  # origin<->peer connection *at all* during boot. Passing `connection:
  # :standard_io` instead of `name:`/`host:` starts the child as a
  # non-distributed "alternative" peer — `:peer`'s own I/O-pipe-based
  # control channel (used for `:peer.call/4` below and `:peer.stop/1` at
  # cleanup) works identically either way, since it's entirely separate
  # from Erlang distribution. Then this test calls `:net_kernel.start/2`
  # *on the peer itself*, via `:peer.call/4` (not `:erpc.call`, which
  # wouldn't have anywhere to reach yet) — this makes the peer a real
  # distributed node under the exact name/host we want, but critically,
  # calling `:net_kernel.start/2` directly does not carry `:peer`'s
  # own "phone home to my controller" side effect, so no auto-connection
  # happens. That leaves a clean window, with the peer fully distributed
  # but genuinely unconnected to anything, to make *this* test's own
  # first-ever connection to it explicitly hidden via
  # `:net_kernel.hidden_connect_node/1` — confirmed empirically to hold
  # (peer's `Node.list()` stays empty of the origin even after the
  # connect). This is now unconditional and correct regardless of
  # whether THIS test's own origin node is itself hidden or not, and
  # regardless of what order the three `:peer`-based test files run in —
  # closing the gap the `setup_all` comment above used to describe as
  # unclosed. (An earlier attempt tried retrofitting hidden-ness onto an
  # *existing* regular connection via `:net_kernel.disconnect/1` +
  # `:net_kernel.hidden_connect_node/1` — confirmed that doesn't work:
  # peers started with `name:` self-terminate on losing their connection
  # to their controller, since `peer.erl`'s own `terminate/2` /
  # `wait_disconnected/2` treat that connection as their liveness
  # tether. Avoiding the auto-connection in the first place, as above,
  # sidesteps that entirely.)
  defp spawn_peers(peer_specs, pa_args) do
    for {alive_name, ordinal, host} <- peer_specs do
      {:ok, pid, _not_yet_named} =
        :peer.start_link(%{
          connection: :standard_io,
          args: pa_args,
          env: [{~c"HOSTNAME", to_charlist(ordinal)}]
        })

      node = :"#{alive_name}@#{to_string(host)}"

      {:ok, _kernel_pid} =
        :peer.call(pid, :net_kernel, :start, [node, %{name_domain: :longnames}])

      assert :net_kernel.hidden_connect_node(node) == true

      {pid, node, ordinal}
    end
  end

  defp push_test_module_to_peers(peers) do
    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"stream_placement_cluster_test.ex",
                 bytecode
               ])
    end
  end

  defp connect_peers(nodes) do
    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end
  end

  defp start_ra_application(peers) do
    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
    end
  end

  defp start_ra_systems(peers) do
    for {_pid, node, _ordinal} <- peers do
      case :erpc.call(node, :ra_system, :start, [
             :erpc.call(node, Riptide.RaCluster, :system_config, [])
           ]) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp bootstrap_placement_cluster(peers, nodes) do
    results =
      Enum.map(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster.Placement, :start_genesis_placement_cluster, [nodes])
      end)

    assert Enum.any?(results, &(&1 == :ok))
  end

  # Riptide.Application never boots on a bare :peer node (it never runs
  # Riptide.Application.start/2 at all), so Riptide.Stream.Placement's
  # ETS-owning GenServer needs starting explicitly here, same as the Ra
  # system pre-start above.
  #
  # NEW GOTCHA (found empirically while implementing this test, beyond the
  # brief's own list): calling `Riptide.Stream.Placement.start_link/1`
  # directly as the erpc-dispatched function — i.e.
  # `:erpc.call(node, Riptide.Stream.Placement, :start_link, [[]])`, as the
  # brief's own draft code originally had it — returns `{:ok, pid}`
  # successfully, but that `pid` is dead within milliseconds afterwards
  # (confirmed via `Process.monitor/1` racing a live process vs. an
  # already-gone one, and via `Process.alive?/1` shortly after). Root
  # cause, isolated with a minimal repro outside this test: `:erpc.call/4`
  # executes the given MFA in a process on the target node that does NOT
  # survive past returning its result — even though the MFA itself
  # returned normally (not an exception), whatever `:erpc` does with that
  # worker process afterwards is NOT equivalent to a plain, unlinked
  # function return. Since `GenServer.start_link/3` (which
  # `Placement.start_link/1` wraps) links the new GenServer to its caller —
  # here, that transient erpc worker — the GenServer dies right along with
  # it. Confirmed this is erpc-specific, not a general "linked process
  # exits normally" fact: the identical call via a plain
  # `:erlang.spawn(node, Riptide.Stream.Placement, :start_link, [[]])`
  # (bypassing erpc entirely) leaves the GenServer alive and well past the
  # call. `Riptide.RaCluster.attempt_start_placement_cluster/1` (now `start_genesis_placement_cluster/1`) and
  # `start_or_restart/2` elsewhere in this same test are unaffected because
  # `:ra` starts its servers under its own supervision tree
  # (`ra_server_sup`), never linked to the calling process — this is
  # specific to a bare `start_link/1,3` invoked with no supervisor of its
  # own, which is exactly `Riptide.Stream.Placement`'s (and, below,
  # `Phoenix.PubSub`'s) situation on a bare `:peer` node that never runs
  # `Riptide.Application`'s real supervision tree. Fix: `start_unlinked/4`
  # below.
  defp start_placement_server(peers) do
    for {_pid, node, _ordinal} <- peers do
      {:ok, _pid} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
    end
  end

  # `Riptide.Stream.StreamServer.append/2` broadcasts every appended event
  # over `Phoenix.PubSub.broadcast(Riptide.PubSub, ...)` (see
  # `Riptide.Application`'s own supervision tree, `{Phoenix.PubSub, name:
  # Riptide.PubSub}`) — another thing a bare `:peer` node never boots.
  #
  # NEW GOTCHA (found empirically, beyond the brief's own list, two layers
  # deep): (1) `Phoenix.PubSub`'s default adapter (`Phoenix.PubSub.PG2`)
  # joins a `:pg` *scope* literally named `Phoenix.PubSub` — that scope is
  # started by `phoenix_pubsub`'s own OTP application callback
  # (`Phoenix.PubSub.Application`, `{:pg, :start_link, [Phoenix.PubSub]}`),
  # not by `Riptide.Application` at all, and not by anything this test had
  # already started — omitting it surfaced as `Phoenix.PubSub.broadcast/3`
  # failing with a `:noproc` `gen_server.call` deep inside the adapter's
  # `join_local`. Fixed by `Application.ensure_all_started(:phoenix_pubsub)`
  # per peer; safe to call directly via `:erpc.call` (unlike the
  # `start_link` cases above) because `Application.ensure_all_started/1`
  # is driven by the already-running, node-permanent
  # `:application_controller` process, never linked to whichever transient
  # process erpc used to dispatch the call. (2) Actually starting the
  # *named* `Riptide.PubSub` instance itself still needs
  # `Phoenix.PubSub.Supervisor.start_link/1` — a real `Supervisor.start_link/3`
  # under the hood, so it has the exact same erpc-link-death problem as
  # `Riptide.Stream.Placement.start_link/1` above. Unlike `GenServer`,
  # though, `Supervisor` (`:supervisor.module_info(:exports)`, confirmed)
  # exposes no unlinked `start/2,3` counterpart to reach for — hence
  # `start_unlinked/4` below, a general workaround rather than an
  # OTP-provided one.
  defp start_pubsub(peers) do
    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

      {:ok, _pid} =
        start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])
    end
  end

  # Starts `apply(mod, fun, args)` on `node` without linking whatever it
  # starts to the transient process `:erpc.call/4` uses to dispatch the
  # call — see the two "NEW GOTCHA" comments above for why a direct
  # `:erpc.call` of a `start_link`-shaped function is unsafe here.
  # `Kernel.spawn/1` (not `spawn_link`) creates an unlinked process on
  # `node`; since nothing needs to outlive *that* process's own death, it's
  # immune to the same problem. It runs the real `start_link` call (which
  # still links normally to whatever it starts, exactly as intended),
  # reports the result back over a genuine cross-node message, then parks in
  # `Process.sleep(:infinity)` forever so it never becomes the next process
  # whose death takes its linked child down with it. This does mean each
  # call leaks one permanently-parked process on `node` — acceptable here
  # since `node` itself is a whole disposable `:peer` torn down at
  # `on_exit`.
  defp start_unlinked(node, mod, fun, args, timeout \\ 5_000) do
    parent = self()
    ref = make_ref()

    :erpc.call(node, Kernel, :spawn, [
      fn ->
        result = apply(mod, fun, args)
        send(parent, {ref, result})
        Process.sleep(:infinity)
      end
    ])

    receive do
      {^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  defp stop_peers_and_cleanup(peers, peer_specs) do
    Enum.each(peers, fn {pid, _node, _ordinal} ->
      if Process.alive?(pid) do
        try do
          :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    # Same on-disk-leak gotcha as placement_cluster_test.exs (:peer nodes
    # don't load Mix config, so RaCluster.data_dir/0 falls through to
    # File.cwd!()) — clean up every ordinal's data directory under the repo
    # root, which now holds both the placement cluster's own data and any
    # stream data created during the test.
    Enum.each(peer_specs, fn {_alive_name, ordinal, _host} ->
      File.rm_rf!(Path.join(File.cwd!(), ordinal))
    end)
  end
end
