defmodule RiptideWeb.Hub.ReviewControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Riptide.Authz.Store
  alias Riptide.Derivation.Catalog

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify("other-token"), do: {:ok, %{"sub" => "someone-else"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    :ok
  end

  defp claim_tenant(tenant_id, owner_sub \\ "the-owner") do
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, owner_sub)
  end

  defp propose(tenant_id, predicate_name) do
    trace1 =
      "#{predicate_name}(<urn:test:alice>, \"hi\") :- pendingDeploy(<urn:test:alice>, \"v1\")."

    trace2 = "#{predicate_name}(<urn:test:bob>, \"hi\") :- pendingDeploy(<urn:test:bob>, \"v1\")."

    body =
      Jason.encode!(%{
        "trace1" => trace1,
        "trace2" => trace2,
        "facts" => [
          %{
            "subject" => "urn:test:alice",
            "predicate" => "urn:riptide:relation:pendingDeploy",
            "object" => "v1"
          },
          %{
            "subject" => "urn:test:bob",
            "predicate" => "urn:riptide:relation:pendingDeploy",
            "object" => "v1"
          }
        ]
      })

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/propose", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    Jason.decode!(conn.resp_body)["node_id"]
  end

  test "the proposing Tenant's own owner can approve their own pending review" do
    tenant_id = "hub-review-test-" <> Uniq.UUID.uuid4()
    predicate_name = "reviewapprove#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    node_id = propose(tenant_id, predicate_name)

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/pending-reviews/#{node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200

    predicate = RDF.iri("urn:riptide:relation:" <> predicate_name)
    assert {:ok, entries} = Catalog.list_entries(:hub)
    assert Enum.any?(entries, fn {_node, rule} -> rule.head.predicate == predicate end)
  end

  test "a different Tenant's own approve attempt 404s — the review only ever exists in the proposing Tenant's own queue" do
    tenant_id = "hub-review-test-" <> Uniq.UUID.uuid4()
    other_tenant_id = "hub-review-other-" <> Uniq.UUID.uuid4()
    predicate_name = "reviewdeny#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)
    claim_tenant(other_tenant_id, "someone-else")

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    node_id = propose(tenant_id, predicate_name)

    conn =
      :post
      |> conn("/tenants/#{other_tenant_id}/hub/pending-reviews/#{node_id}/approve")
      |> put_req_header("authorization", "Bearer other-token")
      |> RiptideWeb.Endpoint.call(@opts)

    # The request itself is authorized (other_tenant_id's own owner posting
    # to other_tenant_id's own route) — DedupGate.approve_review/3 reads
    # review_scope's own pending-review stream (§5), and this node was
    # never queued there, so the lookup simply misses. A 404 here doesn't
    # leak whether the review exists under some other Tenant.
    assert conn.status == 404
  end

  test "decline resolves the review and admits nothing" do
    tenant_id = "hub-review-test-" <> Uniq.UUID.uuid4()
    predicate_name = "reviewdecline#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    node_id = propose(tenant_id, predicate_name)

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/pending-reviews/#{node_id}/decline")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200

    predicate = RDF.iri("urn:riptide:relation:" <> predicate_name)
    assert {:ok, entries} = Catalog.list_entries(:hub)
    refute Enum.any?(entries, fn {_node, rule} -> rule.head.predicate == predicate end)
  end
end
