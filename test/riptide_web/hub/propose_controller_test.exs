defmodule RiptideWeb.Hub.ProposeControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Riptide.Authz.Store
  alias Riptide.Derivation.Catalog

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
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")
  end

  test "an authenticated owner can propose two fact-pattern-only ground Traces to Hub scope" do
    tenant_id = "hub-propose-test-" <> Uniq.UUID.uuid4()
    predicate_name = "proposetest#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)

    # :hub is shared and disk-persisted across the whole test suite (never
    # force-deleted — see catalog_test.exs's own "Hub vs. Tenant scope
    # isolation" test), so only the review-queue stream (isolated per
    # unique tenant_id) is cleaned up here.
    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    trace1 =
      "#{predicate_name}(<urn:test:alice>, \"hi\") :- pendingDeploy(<urn:test:alice>, \"v1\")."

    trace2 =
      "#{predicate_name}(<urn:test:bob>, \"hi\") :- pendingDeploy(<urn:test:bob>, \"v1\")."

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

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert response["outcome"] == "queued"
    assert response["kind"] == "admit"
    assert is_binary(response["node_id"])

    assert {:ok, review_entries} = Catalog.list_pending_reviews({:tenant, tenant_id})

    assert Enum.any?(review_entries, fn {node, _} ->
             RDF.BlankNode.value(node) == response["node_id"]
           end)
  end

  test "an unauthenticated caller is denied" do
    tenant_id = "hub-propose-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body =
      Jason.encode!(%{
        "trace1" => "x(<urn:test:a>, \"y\").",
        "trace2" => "x(<urn:test:b>, \"y\").",
        "facts" => []
      })

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/propose", body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 403
  end
end
