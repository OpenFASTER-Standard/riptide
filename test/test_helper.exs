ExUnit.start()

# SIDE-FIX (2026-08-25): give the test-runner BEAM a stable, real distributed
# identity ONCE, here, before the placement-cluster bootstrap below ever
# calls node(). Without this, node() is :nonode@nohost at bootstrap time (the
# test-runner BEAM isn't distributed yet), so the shared placement cluster's
# Ra server permanently registers under {:riptide_placement, :nonode@nohost}.
# Later, whichever of the 3 :peer-based test files
# (placement_cluster_test.exs / multi_node_connectivity_test.exs /
# stream/stream_placement_cluster_test.exs) happens to run first calls
# Node.start/2 in its own setup_all, which makes this BEAM distributed for
# real — a one-way, whole-VM change of node() for the rest of the `mix test`
# process's lifetime. Erlang's {Name, Node} process addressing requires the
# CURRENT node identity to match, so it does NOT retroactively re-register
# the already-running Ra server under the new node() — it's simply orphaned.
# Every later test touching Riptide.Placement/Riptide.Stream.Placement then
# fails with "Ra consistent query failed for {:riptide_placement,
# :nonode@nohost}: :noproc". Confirmed real (not speculative) by two
# independent parties reproducing it, including with the newest :peer-based
# test file removed entirely — order-dependent on which of the other 2 files
# runs first. Establishing the identity here, before bootstrap, means every
# test file's own `unless Node.alive?() do Node.start(...) end` guard just
# sees Node.alive?() == true already and skips straight through, no matter
# which file runs first — node() never changes again after this point.
#
# Started HIDDEN (via :net_kernel.start/2's hidden: true — Node.start/2,3
# doesn't expose this option) rather than as a normal visible node. This
# matters for a second, separate reason: Riptide.Placement.propose_nodes/2
# (exercised by the regular async suite through Riptide.Stream.StreamServer)
# defaults its candidate list to `Node.list() ++ [node()]`. ExUnit runs
# async: false files concurrently with async: true ones, so while this
# suite's regular async tests are running, one of the 3 :peer-based files
# could be mid-flight too — and placement_cluster_test.exs /
# multi_node_connectivity_test.exs spawn peers via `:peer.start_link(%{name:
# ..., host: ...})`, which auto-connects each peer straight back to THIS
# (the origin/controller) node as an ordinary connection, before
# :peer.start_link/1 even returns. If this origin node were visible, a
# stray peer from a completely unrelated test file could transiently show
# up in this node's own Node.list() and get proposed as a bogus member of a
# stream created on the origin around the same time — a real correctness
# bug, not just test noise.
#
# Confirmed empirically (not just reasoned about) that `hidden: true` here
# closes that gap without breaking anything: a connection where either side
# is a hidden node is treated as hidden SYMMETRICALLY by Erlang's default
# Node.list()/nodes() — i.e. this hidden origin's own Node.list() excludes
# even a plain, non-hidden peer connected to it (confirmed via a real
# :peer.start_link(%{name: ..., host: ...}) against a hidden origin: the
# peer showed up only in Node.list(:hidden), never in the default
# Node.list()), AND that same non-hidden peer's own default Node.list()
# symmetrically excludes this hidden origin too. Meanwhile :erpc.call/4 and
# :peer.call/4 (the RPC/control-plane primitives every :peer-based test
# relies on throughout) work identically regardless of hidden status in
# either direction — confirmed both ways. stream_placement_cluster_test.exs's
# own explicit `:net_kernel.hidden_connect_node/1` call (made FROM this
# origin, to make ITS OWN peer connections hidden) also still returns `true`
# and behaves identically whether this origin was already hidden or not —
# confirmed via a standalone repro mirroring that file's exact
# connection: :standard_io + :peer.call(net_kernel, :start, ...) dance.
# `placement_cluster_test.exs`/`multi_node_connectivity_test.exs` don't rely
# on Node.list() including this origin (they build their own explicit node
# lists via resolve_fun/erpc, or only assert mutual visibility among their
# own peers), so hiding it costs them nothing.
unless Node.alive?() do
  {:ok, _pid} =
    :net_kernel.start(:"test_helper_origin@127.0.0.1", %{
      name_domain: :longnames,
      hidden: true
    })
end

# Riptide.Application's own placement-cluster bootstrap only runs on pods
# whose HOSTNAME matches one of the 3 fixed ordinals — never true here. This
# gives the whole async suite a real, running (single-node-collapsed)
# placement cluster to assign/lookup against, so every test that goes
# through Riptide.Stream.Placement (Phase 3c-ii) can exercise real
# Placement.assign/2/lookup/2 calls, not just pure logic. Uses the same
# config-driven ordinal_resolver Step 3 just added (config/test.exs), not
# an explicit resolver here — this must resolve exactly the same way
# Placement.assign/2/lookup/2's own default argument will later, or the
# bootstrapped cluster and later calls address different servers.
#
# Now runs under a stable, real node() (set immediately above) rather than
# :nonode@nohost — see the SIDE-FIX comment above for why that stability is
# required for this bootstrap to survive the rest of the suite.
:ok = Riptide.RaCluster.attempt_start_placement_cluster()
