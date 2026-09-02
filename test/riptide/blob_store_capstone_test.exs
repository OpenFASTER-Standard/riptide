defmodule Riptide.BlobStoreCapstoneTest do
  use ExUnit.Case, async: false

  alias Riptide.Authz.Policy
  alias Riptide.BlobStore
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
    dir = Path.join(System.tmp_dir!(), "blob_capstone_#{System.unique_integer([:positive])}")
    Riptide.AppEnvTestHelpers.put_env(:riptide, :blob_data_dir, dir)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)

    FakeStore.start(%{
      {"acme", ["capabilities", "greetPerson"]} => [
        %Policy{effect: :allow, modes: [:invoke], matcher: :public}
      ]
    })

    on_exit(fn ->
      File.rm_rf!(dir)

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

  test "exit criterion (issue #72): a Capability's output is stored as a blob, retrievable via a hash-pointer Fact" do
    definition = %Definition{
      name: RDF.iri("urn:riptide:capability:greetPerson"),
      kind: :effect,
      component: "test/fixtures/riptide_capability/fixture.wasm",
      function: "greet",
      fuel_limit: 100_000_000,
      timeout_ms: 5_000,
      memory_limits: %{
        max_memory_size: nil,
        max_table_elements: nil,
        max_instances: nil,
        max_tables: nil
      }
    }

    assert {:ok, output} = Capability.invoke(definition, "acme", nil, ["World"])

    assert {:ok, hash} = BlobStore.put("acme", output)

    # The hash-pointer Fact: an ordinary RDF triple a real ExecuteInterpreter
    # caller would write onto whatever resource this Capability's result
    # attaches to — hand-built here since general Capability-output-to-blob
    # wiring is explicitly out of scope for this phase (spec §3).
    fact =
      {RDF.iri("urn:test:greeting-result"), RDF.iri("urn:test:attachment"),
       RDF.iri("urn:riptide-blob:sha256:" <> hash)}

    graph = RDF.Graph.new([fact])

    extracted_hash =
      graph
      |> RDF.Graph.get(RDF.iri("urn:test:greeting-result"))
      |> RDF.Description.first(RDF.iri("urn:test:attachment"))
      |> RDF.IRI.to_string()
      |> String.trim_leading("urn:riptide-blob:sha256:")

    assert extracted_hash == hash
    assert {:ok, ^output} = BlobStore.get("acme", extracted_hash)
  end
end
