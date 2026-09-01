defmodule RiptideWeb.TenantExecutionSurfaceCapstoneTest do
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
    def complete(prompt) do
      # `capability(localName, arg, ResultVar)` is LLMFallback's own established DSL syntax for a
      # CapabilityReference literal (see Task 5's own StubLLMClient comment for the confirmed
      # precedent this mirrors). The two Task descriptions ("about alice" / "about bob") map
      # deterministically to a different capability arg, so both resolve differently enough for
      # AntiUnifier to generalize a real least-general-generalization from them, exactly like a
      # real LLM resolving two structurally-similar-but-distinct requests.
      name = if String.contains?(prompt, "alice"), do: "Alice", else: "Bob"

      {:ok,
       "capstoneDone(<urn:test:capstone-subject>, Result) :- capability(capstoneGreet, \"#{name}\", Result)."}
    end
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :llm_fallback_client, StubLLMClient)
    :ok
  end

  defp register_capstone_capability(tenant_id) do
    component_bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")
    {:ok, hash} = Riptide.BlobStore.put(component_bytes)

    entry = %Riptide.Derivation.CapabilityCatalogEntry{
      name: RDF.iri("urn:riptide:capability:capstoneGreet"),
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
        ["capabilities", "capstoneGreet"],
        %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
      )
  end

  test "exit criterion: Task -> LLMFallback -> propose -> approve -> Task -> Discovery, zero LLM calls" do
    tenant_id = "tenant-surface-capstone-" <> Uniq.UUID.uuid4()
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")
    register_capstone_capability(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id))
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
    end)

    # 1. First Task -> no CatalogEntry -> LLMFallback.
    job1_node = submit_task(tenant_id, "capstone task about alice", [], "llm_fallback")

    # 2. Second, similar Task -> also LLMFallback (still no CatalogEntry).
    job2_node = submit_task(tenant_id, "capstone task about bob", [], "llm_fallback")

    # 3. Propose the two Jobs' own recorded Traces against each other.
    propose_body = Jason.encode!(%{"job1" => job1_node, "job2" => job2_node})

    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/propose", propose_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert propose_conn.status == 200
    assert Jason.decode!(propose_conn.resp_body)["outcome"] == "queued"

    assert {:ok, [{review_node, _pending}]} = Catalog.list_pending_reviews({:tenant, tenant_id})

    # 4. Approve it.
    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/pending-reviews/#{RDF.BlankNode.value(review_node)}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200
    assert {:ok, [{_node, _entry}]} = Catalog.list_entries({:tenant, tenant_id})

    # 5. A third, similar Task now resolves via Discovery — zero LLMFallback calls.
    # `Discovery.tokenize/1` (the query side) only lowercases/splits on
    # non-alphanumeric — unlike `camel_words/1` (the predicate side), it does
    # NOT split camelCase — so a space-separated phrase is needed for the
    # query to word-match the "capstoneDone" predicate's own split words
    # ["capstone", "done"] (confirmed against Riptide.Derivation.Discovery
    # directly: "capstoneDone" as a query tokenizes to the single word
    # "capstonedone", which never overlaps).
    job3_node = submit_task(tenant_id, "capstone done", [], "discovery")

    {:ok, jobs} = Catalog.list_jobs(Catalog.job_stream_id(tenant_id))
    {_node, job3} = Enum.find(jobs, fn {n, _j} -> RDF.BlankNode.value(n) == job3_node end)
    assert job3.resolved_via == :discovery
    assert job3.trace == nil
  end

  defp submit_task(tenant_id, description, facts, expected_resolved_via) do
    body = Jason.encode!(%{"description" => description, "facts" => facts})

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/tasks", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 202
    response = Jason.decode!(conn.resp_body)
    assert response["resolved_via"] == expected_resolved_via
    response["job_node"]
  end
end
