defmodule RiptideWeb.Hub.InstallControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Riptide.Authz.Store
  alias Riptide.Derivation.{Catalog, Parser, Provenance}

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

  test "install a Hub entry into a Tenant, then approve — it becomes live in the Tenant's own Catalog" do
    tenant_id = "install-test-" <> Uniq.UUID.uuid4()
    predicate_name = "installhttp#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    hub_rule_text =
      "#{predicate_name}(<urn:test:alice>, \"hi\") :- pendingDeploy(<urn:test:alice>, \"v1\")."

    {:ok, hub_rule} = Parser.decode(hub_rule_text)
    :ok = Catalog.admit_entry(:hub, hub_rule, nil)
    {:ok, hub_entries} = Catalog.list_entries(:hub)
    {hub_node, ^hub_rule} = Enum.find(hub_entries, fn {_n, r} -> r == hub_rule end)
    hub_node_id = RDF.BlankNode.value(hub_node)

    body = Jason.encode!(%{"hub_node_id" => hub_node_id})

    install_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/install", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert install_conn.status == 200
    review_node_id = Jason.decode!(install_conn.resp_body)["node_id"]

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/install-reviews/#{review_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    predicate = RDF.iri("urn:riptide:relation:" <> predicate_name)
    assert {:ok, entries} = Catalog.list_entries({:tenant, tenant_id})
    assert Enum.any?(entries, fn {_n, r} -> r.head.predicate == predicate end)
  end

  test "exit criterion (issue #71): install with partial vocabulary overlap binds matched fields through a Crosswalk and records manually-originated Provenance for unmatched fields" do
    installing_tenant = "install-capstone-" <> Uniq.UUID.uuid4()
    claim_tenant(installing_tenant)

    source_predicate_name = "pendingDeployCapstone#{System.unique_integer([:positive])}"
    target_predicate_name = "deploymentQueuedCapstone#{System.unique_integer([:positive])}"
    unmatched_predicate_name = "notifyChannelCapstone#{System.unique_integer([:positive])}"
    pattern_predicate_name = "deployNotifyCapstone#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(
        Catalog.catalog_stream_id({:tenant, installing_tenant})
      )

      Riptide.RaTestHelpers.cleanup_stream(
        Catalog.pending_review_stream_id({:tenant, installing_tenant})
      )
    end)

    # The installing Tenant already has an entry using its own vocabulary word.
    existing_rule_text =
      "existing#{pattern_predicate_name}(<urn:test:a>, \"hi\") :- #{target_predicate_name}(<urn:test:a>, \"v1\")."

    {:ok, existing_rule} = Parser.decode(existing_rule_text)
    :ok = Catalog.admit_entry({:tenant, installing_tenant}, existing_rule, nil)

    # Propose and approve a Crosswalk from the Hub pattern's own predicate to
    # the installing Tenant's.
    crosswalk_body =
      Jason.encode!(%{
        "subject_predicate" => "urn:riptide:relation:#{source_predicate_name}",
        "object_predicate" => "urn:riptide:relation:#{target_predicate_name}",
        "match_type" => "exact_match"
      })

    crosswalk_propose_conn =
      :post
      |> conn("/tenants/#{installing_tenant}/hub/crosswalks", crosswalk_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert crosswalk_propose_conn.status == 200
    crosswalk_node_id = Jason.decode!(crosswalk_propose_conn.resp_body)["node_id"]

    crosswalk_approve_conn =
      :post
      |> conn("/tenants/#{installing_tenant}/hub/crosswalk-reviews/#{crosswalk_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert crosswalk_approve_conn.status == 200

    # Publish the Hub pattern — two predicates: one has a Crosswalk to the
    # installing Tenant's vocabulary, one doesn't.
    hub_rule_text =
      "#{pattern_predicate_name}(<urn:test:a>, \"hi\") :- " <>
        "#{source_predicate_name}(<urn:test:a>, \"v1\"), #{unmatched_predicate_name}(<urn:test:a>, \"v1\")."

    {:ok, hub_rule} = Parser.decode(hub_rule_text)
    :ok = Catalog.admit_entry(:hub, hub_rule, nil)
    {:ok, hub_entries} = Catalog.list_entries(:hub)
    {hub_node, ^hub_rule} = Enum.find(hub_entries, fn {_n, r} -> r == hub_rule end)
    hub_node_id = RDF.BlankNode.value(hub_node)

    install_body = Jason.encode!(%{"hub_node_id" => hub_node_id})

    install_conn =
      :post
      |> conn("/tenants/#{installing_tenant}/hub/install", install_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert install_conn.status == 200
    install_node_id = Jason.decode!(install_conn.resp_body)["node_id"]

    install_approve_conn =
      :post
      |> conn("/tenants/#{installing_tenant}/hub/install-reviews/#{install_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert install_approve_conn.status == 200

    pattern_predicate = RDF.iri("urn:riptide:relation:#{pattern_predicate_name}")
    target_predicate = RDF.iri("urn:riptide:relation:#{target_predicate_name}")
    source_predicate = RDF.iri("urn:riptide:relation:#{source_predicate_name}")
    unmatched_predicate = RDF.iri("urn:riptide:relation:#{unmatched_predicate_name}")

    assert {:ok, entries} = Catalog.list_entries({:tenant, installing_tenant})

    {_node, installed_rule} =
      Enum.find(entries, fn {_n, r} -> r.head.predicate == pattern_predicate end)

    body_predicates = Enum.map(installed_rule.body, & &1.predicate)
    assert target_predicate in body_predicates
    assert unmatched_predicate in body_predicates
    refute source_predicate in body_predicates

    assert %Provenance{origin: {:installed_from, ^hub_node, field_bindings}} =
             installed_rule.provenance

    assert Enum.any?(field_bindings, fn
             %{predicate: ^source_predicate, binding: {:crosswalk, _crosswalk_node}} -> true
             _other -> false
           end)

    assert Enum.any?(field_bindings, fn
             %{predicate: ^unmatched_predicate, binding: :manual} -> true
             _other -> false
           end)
  end
end
