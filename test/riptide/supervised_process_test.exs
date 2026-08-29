defmodule Riptide.SupervisedProcessTest do
  use ExUnit.Case, async: false

  alias Riptide.SupervisedProcess

  defmodule Fixture do
    @behaviour Riptide.SupervisedProcess
    use GenServer

    @impl GenServer
    def init({id, active}), do: {:ok, %{id: id, active: active}}

    @impl GenServer
    def handle_call(:set_active, _from, state), do: {:reply, :ok, %{state | active: true}}
    def handle_call(:set_idle, _from, state), do: {:reply, :ok, %{state | active: false}}

    def handle_call({:riptide_supervised_process, :stop_if_idle, reason}, from, state) do
      Riptide.SupervisedProcess.handle_stop_if_idle(__MODULE__, state, reason, from)
    end

    @impl Riptide.SupervisedProcess
    def session_active?(state), do: state.active
  end

  defp unique_id, do: "fixture-#{System.unique_integer([:positive])}"

  describe "start/3" do
    test "starts the process and registers it under id for lookup" do
      id = unique_id()

      assert {:ok, pid} = SupervisedProcess.start(id, Fixture, {id, false})
      assert Process.alive?(pid)
      assert [{^pid, Fixture}] = Registry.lookup(Riptide.SupervisedProcess.Registry, id)
    end

    test "two different ids each get their own independently-addressable process" do
      id_a = unique_id()
      id_b = unique_id()

      {:ok, pid_a} = SupervisedProcess.start(id_a, Fixture, {id_a, false})
      {:ok, pid_b} = SupervisedProcess.start(id_b, Fixture, {id_b, false})

      assert pid_a != pid_b
      assert [{^pid_a, Fixture}] = Registry.lookup(Riptide.SupervisedProcess.Registry, id_a)
      assert [{^pid_b, Fixture}] = Registry.lookup(Riptide.SupervisedProcess.Registry, id_b)
    end
  end

  describe "request_restart/1 — idle process" do
    test "succeeds, and a fresh process comes back under the same id via :transient" do
      id = unique_id()
      {:ok, pid} = SupervisedProcess.start(id, Fixture, {id, false})

      assert :ok = SupervisedProcess.request_restart(id)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

      # :transient restarts on this abnormal exit reason, using the same
      # child spec (same module/init_arg) — a fresh process re-registers
      # under the same id without any new start/3 call.
      wait_until(fn ->
        case Registry.lookup(Riptide.SupervisedProcess.Registry, id) do
          [{new_pid, Fixture}] -> new_pid != pid
          [] -> false
        end
      end)
    end
  end

  describe "request_restart/1 — active session" do
    test "is refused, and the original process is confirmed still running unchanged" do
      id = unique_id()
      {:ok, pid} = SupervisedProcess.start(id, Fixture, {id, false})
      :ok = GenServer.call(pid, :set_active)

      assert {:error, :session_active} = SupervisedProcess.request_restart(id)

      assert Process.alive?(pid)
      assert [{^pid, Fixture}] = Registry.lookup(Riptide.SupervisedProcess.Registry, id)
    end
  end

  describe "request_restart/1 — unregistered id" do
    test "returns {:error, :not_found}" do
      assert {:error, :not_found} = SupervisedProcess.request_restart(unique_id())
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts <= 1 do
        flunk("condition never became true")
      else
        Process.sleep(10)
        wait_until(fun, attempts - 1)
      end
    end
  end
end
