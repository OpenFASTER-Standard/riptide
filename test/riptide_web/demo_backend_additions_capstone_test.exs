defmodule RiptideWeb.DemoBackendAdditionsCapstoneTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.Store
  alias Riptide.Derivation.{Catalog, Rule, Signature}
  alias Riptide.Derivation.Literal.FactPattern

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier
    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    :ok
  end

  defp claim_tenant(tenant_id) do
    :ok =
      Store.TenantFacts.add_policy(tenant_id, [], %Riptide.Authz.Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: {:agent, "the-owner"}
      })
  end

  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)
  defp t(name), do: RDF.iri("urn:test:" <> name)

  test "query over an admitted rule + a named starting resource returns the derived facts" do
    tenant_id = "capstone-6p-i-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
    end)

    # Same deliberately-ground rule shape as TenantQueryControllerTest's own — proving the
    # exit criterion end-to-end (propose/admit already covered elsewhere; this proves the new
    # query endpoint reaches it), not re-testing QueryInterpreter's own recursion algorithm.
    rule = %Rule{
      signature: %Signature{
        name: rel("unlocks"),
        parameters: [],
        reads: [rel("unlocks")],
        produces: [rel("unlocks")]
      },
      head: %FactPattern{predicate: rel("unlocks"), args: [t("a"), t("c")]},
      body: [%FactPattern{predicate: rel("unlocks"), args: [t("a"), t("b")]}]
    }

    :ok = Catalog.admit_entry({:tenant, tenant_id}, rule, nil)

    :put
    |> conn(
      "/tenants/#{tenant_id}/resources/characters/alice",
      "<urn:test:a> <urn:riptide:relation:unlocks> <urn:test:b> ."
    )
    |> put_req_header("authorization", "Bearer owner-token")
    |> RiptideWeb.Endpoint.call(@opts)

    query_body = Jason.encode!(%{"starting_resource_path" => ["characters", "alice"]})

    query_conn =
      :post
      |> conn("/tenants/#{tenant_id}/query", query_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert query_conn.status == 200
    assert query_conn.resp_body =~ "urn:test:c"
  end

  test "two same-mutex_key Task submissions never execute concurrently" do
    tenant_id = "capstone-6p-i-mutex-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")
    {:ok, hash} = Riptide.BlobStore.put(bytes)

    cap_name =
      RDF.iri("urn:riptide:capability:capstone-6p-i-#{System.unique_integer([:positive])}")

    entry = %Riptide.Derivation.CapabilityCatalogEntry{
      name: cap_name,
      kind: :effect,
      component_hash: hash,
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

    :ok = Catalog.admit_capability(entry, nil)

    local_name = cap_name |> RDF.IRI.to_string() |> String.trim_leading("urn:riptide:capability:")

    :ok =
      Riptide.Authz.Store.TenantFacts.add_policy(tenant_id, ["capabilities", local_name], %Riptide.Authz.Policy{
        effect: :allow,
        modes: [:invoke],
        matcher: :public
      })

    mutex_key = "capstone-6p-i-shared-chest-#{System.unique_integer([:positive])}"

    job = fn name ->
      %Riptide.Derivation.Job{
        tenant_id: tenant_id,
        status: :pending,
        reference: {:capability, cap_name},
        args: [RDF.literal(name)],
        job_graph: nil,
        result: nil,
        error: nil,
        mutex_key: mutex_key
      }
    end

    stream_id = Catalog.job_stream_id(tenant_id)
    {:ok, _node1} = Catalog.write_job(tenant_id, job.("Alice"))
    {:ok, _node2} = Catalog.write_job(tenant_id, job.("Bob"))

    # Whichever Job loses the mutex_key race on its own {:job_written, stream_id} broadcast
    # gets skipped that round and only retried on the next periodic_sweep — 30s in this test
    # env too, since :job_trigger_sweep_interval_ms has no test-config override (same reasoning
    # job_trigger_cluster_test.exs's own "sharing a mutex_key" test already documents). 250 *
    # 200ms = 50s gives that a real margin.
    assert eventually(
             fn ->
               {:ok, jobs} = Catalog.list_jobs(stream_id)
               length(jobs) == 2 and Enum.all?(jobs, fn {_node, j} -> j.status == :done end)
             end,
             250
           )
  end

  defp eventually(fun, attempts_left) do
    cond do
      fun.() -> true
      attempts_left <= 1 -> false
      true -> Process.sleep(200) && eventually(fun, attempts_left - 1)
    end
  end
end
