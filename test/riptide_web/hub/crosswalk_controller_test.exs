defmodule RiptideWeb.Hub.CrosswalkControllerTest do
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

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    :ok
  end

  defp claim_tenant(tenant_id) do
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")
  end

  defp rel(name), do: "urn:riptide:relation:" <> name

  test "propose a Crosswalk, then approve it — it becomes live in the Hub crosswalk catalog" do
    tenant_id = "crosswalk-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    subject = rel("crosswalkhttp-a#{System.unique_integer([:positive])}")
    object = rel("crosswalkhttp-b#{System.unique_integer([:positive])}")

    body =
      Jason.encode!(%{
        "subject_predicate" => subject,
        "object_predicate" => object,
        "match_type" => "exact_match"
      })

    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/crosswalks", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert propose_conn.status == 200
    node_id = Jason.decode!(propose_conn.resp_body)["node_id"]
    assert is_binary(node_id)

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/crosswalk-reviews/#{node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    assert {:ok, entries} = Catalog.list_crosswalks()

    assert Enum.any?(entries, fn {_n, c} ->
             c.subject_predicate == RDF.iri(subject) and c.object_predicate == RDF.iri(object)
           end)
  end

  test "proposing a Crosswalk with replaces: admits the new version and supersedes the old one" do
    tenant_id = "crosswalk-replaces-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    subject = rel("crosswalkhttpreplaces-#{System.unique_integer([:positive])}")
    object = rel("crosswalkhttpreplaces-obj#{System.unique_integer([:positive])}")

    base_body = %{
      "subject_predicate" => subject,
      "object_predicate" => object,
      "match_type" => "exact_match"
    }

    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/crosswalks", Jason.encode!(base_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    old_node_id = Jason.decode!(propose_conn.resp_body)["node_id"]

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/crosswalk-reviews/#{old_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    {:ok, entries_before} = Catalog.list_crosswalks()

    {old_hub_node, _entry} =
      Enum.find(entries_before, fn {_n, c} -> c.subject_predicate == RDF.iri(subject) end)

    replaces_body =
      base_body
      |> Map.put("match_type", "close_match")
      |> Map.put("replaces", RDF.BlankNode.value(old_hub_node))

    propose_replacement_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/crosswalks", Jason.encode!(replaces_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    new_node_id = Jason.decode!(propose_replacement_conn.resp_body)["node_id"]

    approve_replacement_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/crosswalk-reviews/#{new_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_replacement_conn.status == 200

    {:ok, entries_after} = Catalog.list_crosswalks()

    matching =
      Enum.filter(entries_after, fn {_n, c} -> c.subject_predicate == RDF.iri(subject) end)

    assert length(matching) == 1
  end
end
