defmodule Riptide.RaClusterColdRestartTest do
  # :ra is a single shared OTP application for the whole BEAM node. This test
  # stops and restarts it to simulate a genuine cold restart — doing that
  # from an `async: true` module would disrupt any other test file
  # concurrently depending on a live Ra server, so this module runs alone.
  use ExUnit.Case, async: false

  alias Riptide.RaCluster
  alias Riptide.Test.EchoMachine

  test "a stream's first write survives a cold Ra-system restart" do
    stream_id = "cold-restart-" <> Uniq.UUID.uuid4()
    on_exit(fn -> RaCluster.force_delete(stream_id) end)

    machine = {:module, EchoMachine, %{}}
    server_id = RaCluster.start_or_restart(stream_id, machine)
    {name, _node} = server_id

    assert RaCluster.process_command(server_id, {:add, "a"}) == ["a"]

    # A plain `Application.stop(:ra); Application.start(:ra)` on its own does
    # NOT reproduce the bug: `:ra`'s server registry (`ra_directory`) is
    # ETS-backed in memory plus DETS-backed on disk, and a *graceful* OTP
    # application stop cleanly closes that DETS table (`ra_log_ets`'s
    # `terminate/2` calls `ra_directory:deinit/1`), so a subsequent
    # restart with the same config reopens it intact and `:ra.restart_server/2`
    # succeeds — confirmed empirically while writing this test (see task 1's
    # report). The registry only genuinely loses a server's entry after an
    # *unclean* shutdown (a real `docker rm -f`/SIGKILL, verified separately
    # against a real container in task 2) that skips that graceful close.
    #
    # To deterministically reproduce that here, in a single BEAM, without a
    # real process kill: restart `:ra` and its default system (the part a
    # real cold restart always does), then directly erase this server's
    # entry from the now-freshly-reopened registry — simulating the registry
    # "not recognizing the stream" exactly as the bug report describes,
    # regardless of the precise disk-level mechanism that causes it for real.
    Application.stop(:ra)
    Application.start(:ra)

    # `:ra` is a single OTP application for the whole BEAM node, so stopping
    # it above also tears down the shared, suite-wide placement cluster that
    # `test_helper.exs` bootstraps once before any test runs — not just the
    # one stream-level server this test is specifically exercising. Every
    # other test in the suite that touches
    # `Riptide.Placement`/`Riptide.Stream.Placement` depends on that shared
    # cluster staying alive for the rest of the `mix test` process's
    # lifetime. This module being `async: false` only serializes it against
    # *other* `async: false` modules — it still runs concurrently with the
    # whole `async: true` pool — so without restoring the shared cluster
    # here, immediately, whichever test happens to run around this one hits
    # "Ra consistent query failed for {:riptide_placement, ...}: :noproc"
    # with no crash log at all (a graceful `Application.stop(:ra)` produces
    # none). Confirmed as the real root cause, not a guess: instrumenting
    # both this restart and the exact `consistent_query` failure site with
    # correlated monotonic timestamps showed `Process.whereis(:riptide_placement)`
    # already `nil` the instant `:ra` comes back up, tens of seconds before
    # the failures it caused elsewhere in the suite.
    :ok = RaCluster.start_genesis_placement_cluster([node()])

    # Use the shared `RaCluster.system_config/0` to build the exact same
    # config `RaCluster.ensure_system_started/0` does — see that function's
    # doc for why even a merely-equivalent (not byte-identical) config here
    # is unsafe.
    config = RaCluster.system_config()

    case :ra_system.start(config) do
      {:ok, _} -> :ok
      {:ok, _, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Look up whatever uid the server is *actually* currently registered
    # under (the old buggy implementation's fallback path mints this via
    # `:ra.start_cluster/4`'s internal `new_uid/1` — a random value with no
    # relationship to `stream_id` at all, unlike `RaCluster.uid_for/1`) and
    # erase that registration, so the registry has amnesia about this server
    # exactly like it would after losing the on-disk record of a genuine
    # crash.
    actual_uid = :ra_directory.uid_of(:default, name)
    assert is_binary(actual_uid)
    :ra_directory.unregister_name(:default, actual_uid)
    assert :ra_directory.uid_of(:default, name) == :undefined

    restarted_id = RaCluster.start_or_restart(stream_id, machine)
    assert restarted_id == server_id
    assert RaCluster.consistent_query(restarted_id, & &1) == ["a"]
  end
end
