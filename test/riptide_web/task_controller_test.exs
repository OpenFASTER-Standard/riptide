defmodule RiptideWeb.TaskControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.Store
  alias Riptide.Derivation.Catalog

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  defmodule StubLLMClient do
    @behaviour Riptide.Derivation.LLMFallback.Client

    @impl true
    def complete(_prompt) do
      # `capability(localName, arg1, ..., ResultVar)` is LLMFallback's own established DSL syntax
      # for a CapabilityReference literal (confirmed live against
      # test/riptide/derivation/llm_fallback_test.exs's own existing fixtures, e.g. "greeted(...) :-
      # capability(greetSomeone, \"Alice\", Greeting)."). `resolve_exactly_one_binding/3` inside
      # LLMFallback.run/3 fully grounds this before returning it — the caller never sees a free var.
      {:ok,
       "taskDone(<urn:test:line-1>, Result) :- capability(taskSubmitGreet, \"World\", Result)."}
    end
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    :ok
  end

  defp claim_tenant(tenant_id) do
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")
  end

  defp register_task_submit_capability(tenant_id, local_name) do
    component_bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")
    {:ok, hash} = Riptide.BlobStore.put(component_bytes)

    entry = %Riptide.Derivation.CapabilityCatalogEntry{
      name: RDF.iri("urn:riptide:capability:#{local_name}"),
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

    :ok =
      Riptide.Placement.add_policy(
        tenant_id,
        ["capabilities", local_name],
        %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
      )
  end

  test "no matching CatalogEntry: resolves via LLMFallback, writes a jobCapability Job with resolved_via and trace" do
    tenant_id = "task-submit-llm-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)
    register_task_submit_capability(tenant_id, "taskSubmitGreet")
    Riptide.AppEnvTestHelpers.put_env(:riptide, :llm_fallback_client, StubLLMClient)

    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id)) end)

    body = Jason.encode!(%{"description" => "mark this line done", "facts" => []})

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/tasks", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 202
    response = Jason.decode!(conn.resp_body)
    assert response["resolved_via"] == "llm_fallback"
    job_node = response["job_node"]

    {:ok, jobs} = Catalog.list_jobs(Catalog.job_stream_id(tenant_id))
    {_node, job} = Enum.find(jobs, fn {n, _j} -> RDF.BlankNode.value(n) == job_node end)
    assert job.resolved_via == :llm_fallback
    assert job.original_description == "mark this line done"
    assert %Riptide.Derivation.Rule{} = job.trace
    assert job.reference == {:capability, RDF.iri("urn:riptide:capability:taskSubmitGreet")}
    assert job.args == [RDF.literal("World")]
  end

  test "a matching CatalogEntry: resolves via Discovery, no LLMFallback call, writes a jobRule Job with the Task's own facts as its job_graph" do
    tenant_id = "task-submit-discovery-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id))
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
    end)

    predicate_name = "tasksubmit#{System.unique_integer([:positive])}"
    seed_predicate = "tasksubmitseed#{System.unique_integer([:positive])}"

    rule = %Riptide.Derivation.Rule{
      signature: %Riptide.Derivation.Signature{
        name: RDF.iri("urn:riptide:relation:#{predicate_name}"),
        parameters: [%Riptide.Derivation.Var{name: "Subject"}],
        reads: [RDF.iri("urn:riptide:relation:#{seed_predicate}")],
        produces: [RDF.iri("urn:riptide:relation:#{predicate_name}")]
      },
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: RDF.iri("urn:riptide:relation:#{predicate_name}"),
        args: [%Riptide.Derivation.Var{name: "Subject"}, RDF.literal("done")]
      },
      body: [
        %Riptide.Derivation.Literal.FactPattern{
          predicate: RDF.iri("urn:riptide:relation:#{seed_predicate}"),
          args: [%Riptide.Derivation.Var{name: "Subject"}, RDF.literal("v1")]
        }
      ]
    }

    :ok = Catalog.admit_entry({:tenant, tenant_id}, rule, nil)

    body =
      Jason.encode!(%{
        "description" => predicate_name,
        "facts" => [
          %{
            "subject" => "urn:test:subject-1",
            "predicate" => "urn:riptide:relation:#{seed_predicate}",
            "object" => "v1"
          }
        ]
      })

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/tasks", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 202
    response = Jason.decode!(conn.resp_body)
    assert response["resolved_via"] == "discovery"
    job_node = response["job_node"]

    {:ok, jobs} = Catalog.list_jobs(Catalog.job_stream_id(tenant_id))
    {_node, job} = Enum.find(jobs, fn {n, _j} -> RDF.BlankNode.value(n) == job_node end)
    assert job.resolved_via == :discovery
    assert job.trace == nil
    assert job.reference == {:rule, RDF.iri("urn:riptide:relation:#{predicate_name}")}
    assert job.args == []
    assert job.job_graph != nil

    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(job.job_graph) end)
  end

  test "LLMFallback :no_match returns 422 and writes no Job" do
    tenant_id = "task-submit-no-match-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    defmodule NoMatchClient do
      @behaviour Riptide.Derivation.LLMFallback.Client
      @impl true
      def complete(_prompt), do: {:ok, "not a valid rule at all"}
    end

    Riptide.AppEnvTestHelpers.put_env(:riptide, :llm_fallback_client, NoMatchClient)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id))
    end)

    body = Jason.encode!(%{"description" => "do something nobody registered", "facts" => []})

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/tasks", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 422
    assert {:ok, []} = Catalog.list_jobs(Catalog.job_stream_id(tenant_id))
  end
end
