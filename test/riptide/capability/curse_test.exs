defmodule Riptide.Capability.CurseTest do
  # async: false — same FakeStore-Agent-races-across-test-files reasoning
  # as test/riptide/capability_test.exs and
  # test/riptide/capability/badge_qr_generator_test.exs.
  use ExUnit.Case, async: false

  alias Riptide.Authz.Policy
  alias Riptide.Capability
  alias Riptide.Capability.Definition

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies(tenant_id, path_prefix) do
      Agent.get(__MODULE__, &Map.get(&1, {tenant_id, path_prefix}, []))
    end

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok

    def start(policies_by_prefix) do
      case Agent.start_link(fn -> policies_by_prefix end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)

    FakeStore.start(%{
      {"guild-a", ["capabilities", "curse"]} => [
        %Policy{effect: :allow, modes: [:invoke], matcher: :public}
      ]
    })

    on_exit(fn ->
      if pid = Process.whereis(FakeStore) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp definition do
    %Definition{
      name: RDF.iri("urn:riptide:capability:curse"),
      kind: :effect,
      component: "examples/guild-demo/capabilities/curse/curse.wasm",
      function: "curse",
      fuel_limit: 100_000_000,
      timeout_ms: 5_000,
      memory_limits: %{
        max_memory_size: nil,
        max_table_elements: nil,
        max_instances: nil,
        max_tables: nil
      }
    }
  end

  test "traps immediately via panic, not fuel exhaustion" do
    # Specifically {:error, {:trap, _}}, not just any non-:ok result — this
    # pins the exact failure-mode distinction the design spec is built on
    # (Riptide.Capability.classify_result/2's two genuinely different
    # non-success branches: :resource_exhausted vs {:trap, output}).
    #
    # Asserting on "unreachable" rather than the panic message text itself
    # ("the chest is cursed"): Capability.run_wasmtime/1 passes `-S
    # inherit-stderr=n`, so the guest's own panic message (written via WASI
    # stderr) never reaches the captured output — only wasmtime's own trap
    # report does. Confirmed live: without this, the assertion would have
    # passed even against a missing/unreadable .wasm file (also classified
    # as {:error, {:trap, _}}), which "unreachable" — specific to an actual
    # wasm trap during execution, not a file-loading error — rules out.
    assert {:error, {:trap, output}} = Capability.invoke(definition(), "guild-a", nil, [])
    assert output =~ "unreachable"
  end
end
