defmodule Riptide.Derivation.JobTriggerTest do
  use ExUnit.Case, async: false

  alias Riptide.Derivation.JobTrigger

  @resource_locks_table :job_trigger_resource_locks
  @resource_monitors_table :job_trigger_resource_monitors

  setup do
    on_exit(fn ->
      :ets.delete_all_objects(@resource_locks_table)
      :ets.delete_all_objects(@resource_monitors_table)
    end)

    :ok
  end

  describe "run_exclusively/2 (via test_run_exclusively/2, see its own moduledoc)" do
    test "with resource_key nil, always runs the function, no reservation made" do
      test_pid = self()

      assert :ok = JobTrigger.test_run_exclusively(nil, fn -> send(test_pid, :ran) end)
      assert_receive :ran, 1_000
    end

    test "reserves the resource before returning, so a concurrent second call with the same key is skipped" do
      resource = {"acme", "run-exclusively-test-#{System.unique_integer([:positive])}"}
      test_pid = self()

      # The first task must stay in flight long enough for this test's own
      # follow-up checks to run — run_exclusively/2's reservation is
      # guaranteed present by the time the call returns (it's made
      # synchronously inside handle_call, before the Task is even spawned),
      # but nothing keeps it present afterward if the task's own function
      # completes (and gets monitored-cleaned-up) near-instantly, which a
      # bare `send/2` would. 300ms is a generous margin against the
      # microsecond-scale local ETS operations this test performs while
      # waiting, not a tight race.
      assert :ok =
               JobTrigger.test_run_exclusively(resource, fn ->
                 send(test_pid, :first_started)
                 Process.sleep(300)
                 send(test_pid, :first_done)
               end)

      assert_receive :first_started, 1_000
      assert :ets.lookup(@resource_locks_table, resource) != []

      assert :skipped =
               JobTrigger.test_run_exclusively(resource, fn -> send(test_pid, :second_ran) end)

      refute_receive :second_ran, 500
      assert_receive :first_done, 1_000
    end

    test "releases the resource once the function completes normally, allowing a later call to run" do
      resource = {"acme", "run-exclusively-release-#{System.unique_integer([:positive])}"}
      test_pid = self()

      assert :ok = JobTrigger.test_run_exclusively(resource, fn -> send(test_pid, :done) end)
      assert_receive :done, 1_000

      assert eventually(fn -> :ets.lookup(@resource_locks_table, resource) == [] end)

      assert :ok = JobTrigger.test_run_exclusively(resource, fn -> send(test_pid, :ran_again) end)
      assert_receive :ran_again, 1_000
    end

    test "releases the resource even if the function crashes abnormally, not just on a normal return" do
      resource = {"acme", "run-exclusively-crash-#{System.unique_integer([:positive])}"}

      assert :ok = JobTrigger.test_run_exclusively(resource, fn -> raise "boom" end)
      assert :ets.lookup(@resource_locks_table, resource) != []

      assert eventually(fn -> :ets.lookup(@resource_locks_table, resource) == [] end)

      assert :ok = JobTrigger.test_run_exclusively(resource, fn -> :ok end)
    end
  end

  # 50 * 200ms = 10s, matching this suite's own established eventually/2
  # convention (see e.g. blob_store_cluster_test.exs).
  defp eventually(fun, attempts_left \\ 50) do
    cond do
      fun.() -> true
      attempts_left <= 1 -> false
      true -> Process.sleep(200) && eventually(fun, attempts_left - 1)
    end
  end
end
