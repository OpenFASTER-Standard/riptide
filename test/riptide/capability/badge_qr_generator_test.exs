defmodule Riptide.Capability.BadgeQrGeneratorTest do
  # async: false — FakeStore is a single, fixed-named Agent; running
  # concurrently with other FakeStore-using test files races start/stop
  # against each other (same reasoning as test/riptide/capability_test.exs).
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
      {"guild-a", ["capabilities", "badgeQrGenerator"]} => [
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
      name: RDF.iri("urn:riptide:capability:badgeQrGenerator"),
      kind: :effect,
      component: "examples/guild-demo/capabilities/badge-qr-generator/badge-qr-generator.wasm",
      function: "generate-qr-code",
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

  test "returns well-formed SVG encoding the given text" do
    assert {:ok, result} = Capability.invoke(definition(), "guild-a", nil, ["hello-riptide"])

    # `result` is wasmtime's own printed representation of the WIT string
    # return value (Rust Debug-style quoting) — the exact same shape
    # test/riptide/capability_test.exs's own `result == "\"Hello,
    # Riptide!\""` assertion already relies on. It happens to be valid JSON
    # string-literal syntax, so Jason.decode!/1 correctly unescapes it back
    # to the real SVG text (and would itself raise if wasmtime's output
    # weren't validly escaped).
    svg = Jason.decode!(result)

    assert String.starts_with?(svg, "<?xml")
    assert svg =~ ~r{<svg\b[^>]*>}
    assert String.ends_with?(String.trim(svg), "</svg>")
  end
end
