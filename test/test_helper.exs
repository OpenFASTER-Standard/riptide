ExUnit.start()

# Riptide.Application's own placement-cluster bootstrap only runs on pods
# whose HOSTNAME matches one of the 3 fixed ordinals — never true here. A
# resolver that maps every ordinal to this same test node collapses all 3
# configs to the same real {:riptide_placement, node()} id, exactly the
# pattern already proven safe by ra_cluster_test.exs's own redundant-call
# regression test (Phase 3c-i) — this gives the whole async suite a real,
# running (single-node) placement cluster to assign/lookup against, so
# every test that goes through Riptide.Stream.Placement (Phase 3c-ii) can
# exercise real Placement.assign/2/lookup/2 calls, not just pure logic.
:ok = Riptide.RaCluster.attempt_start_placement_cluster(fn _ordinal -> node() end)
