defmodule Riptide.CapabilityTest do
  # async: false — FakeStore is a single, fixed-named Agent shared by every
  # test in this module; running them concurrently races start/stop against
  # each other (see test/riptide/authz_test.exs, which established this
  # same pattern for the same reason).
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

    @impl true
    def claim_tenant_if_unclaimed(_tenant_id, _subject), do: :already_claimed

    def start(policies_by_prefix) do
      case Agent.start_link(fn -> policies_by_prefix end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)
    on_exit(fn -> if pid = Process.whereis(FakeStore), do: Agent.stop(pid) end)
    :ok
  end

  defp definition(name) do
    %Definition{
      name: RDF.iri("urn:riptide:capability:" <> name),
      kind: :effect,
      component: "test/fixtures/riptide_capability/fixture.wasm",
      function: "greet",
      fuel_limit: 10_000_000,
      timeout_ms: 5_000,
      memory_limits: %{
        max_memory_size: nil,
        max_table_elements: nil,
        max_instances: nil,
        max_tables: nil
      }
    }
  end

  describe "authorized?/3" do
    test "true when a policy grants :invoke on the capability's synthetic path" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetSomeone"]} => [
          %Policy{effect: :allow, modes: [:invoke], matcher: :authenticated}
        ]
      })

      assert Capability.authorized?(definition("greetSomeone"), "acme", %{"sub" => "user-1"})
    end

    test "false with no matching policy (default-deny)" do
      FakeStore.start(%{})

      refute Capability.authorized?(definition("greetSomeone"), "acme", %{"sub" => "user-1"})
    end

    test "false when the policy grants :read but not :invoke" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetSomeone"]} => [
          %Policy{effect: :allow, modes: [:read], matcher: :public}
        ]
      })

      refute Capability.authorized?(definition("greetSomeone"), "acme", nil)
    end

    test "a grant for one capability name doesn't authorize a different one" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetSomeone"]} => [
          %Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      refute Capability.authorized?(definition("deleteEverything"), "acme", nil)
    end
  end
end
