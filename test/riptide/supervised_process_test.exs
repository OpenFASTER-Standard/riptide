defmodule Riptide.SupervisedProcessTest do
  use ExUnit.Case, async: false

  alias Riptide.SupervisedProcess

  defmodule Fixture do
    use GenServer

    @impl GenServer
    def init({id, active}), do: {:ok, %{id: id, active: active}}

    @impl GenServer
    def handle_call(:set_active, _from, state), do: {:reply, :ok, %{state | active: true}}
    def handle_call(:set_idle, _from, state), do: {:reply, :ok, %{state | active: false}}
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
end
