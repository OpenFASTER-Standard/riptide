defmodule Riptide.ApplicationBootstrapRestartTest do
  use ExUnit.Case, async: true

  # Regression test for a real, confirmed-live production bug: a `:permanent`
  # restart Task whose own job normally completes by exiting `:ok` gets
  # restarted anyway (OTP's `:permanent` restarts on ANY exit, including
  # `:normal`) — and if the restarted work ALSO completes immediately (as
  # this Task's own self-correcting retry loop does, once the cluster it's
  # forming already exists), the exit-then-restart cycle repeats fast enough
  # to exceed the supervisor's default restart intensity and crash it
  # entirely. `:transient` is the correct strategy: restart only on an
  # abnormal exit, never on the intended "job's done" normal exit. This test
  # exercises the exact child-spec shape `Riptide.Application` uses, with a
  # stub in place of the real (slow, Ra-dependent) bootstrap function, so it
  # runs fast and needs no real placement cluster.
  test "a :transient Task that exits :ok does not get restarted, and its supervisor survives" do
    {:ok, sup} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Task, fn -> :ok end}, id: :bootstrap_stub, restart: :transient)
        ],
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 5
      )

    # Give the Task time to run, exit :ok, and (incorrectly, if this
    # regresses) be restarted zero or more times.
    Process.sleep(200)

    assert Process.alive?(sup)
  end

  test "a :permanent Task that exits :ok DOES get endlessly restarted and crashes its supervisor" do
    # Demonstrates the actual bug this task fixes, in isolation — proving
    # the test above actually distinguishes :transient from :permanent
    # rather than trivially passing regardless of which strategy is used.
    Process.flag(:trap_exit, true)

    {:ok, sup} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Task, fn -> :ok end}, id: :bootstrap_stub, restart: :permanent)
        ],
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 5
      )

    assert_receive {:EXIT, ^sup, :shutdown}, 2000
  end
end
