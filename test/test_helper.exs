ExUnit.start()

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
:ok = Riptide.RaCluster.attempt_start_placement_cluster()
