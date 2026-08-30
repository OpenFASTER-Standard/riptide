defmodule RiptideWeb.Hub.DiscoveryControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Riptide.Derivation.Catalog
  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{Rule, Signature}

  @opts RiptideWeb.Endpoint.init([])

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  defp sample_rule(predicate_local_name) do
    predicate = rel(predicate_local_name)
    head = %FactPattern{predicate: predicate, args: [t("subject"), RDF.literal("object")]}

    %Rule{
      signature: %Signature{name: predicate, parameters: [], reads: [], produces: [predicate]},
      head: head,
      body: []
    }
  end

  test "GET /hub/search finds a real admitted Hub-scope entry, with no auth token" do
    # :hub is a single, shared, non-unique stream across the whole test
    # suite — never force-deleted from a test (confirmed live: doing so
    # races any other write against that same stream_id). Tolerated by
    # using a unique predicate name and a substring match instead of an
    # exact-list assertion, same as catalog_test.exs's own "Hub vs. Tenant
    # scope isolation" test.
    predicate_name = "discoverysearch#{System.unique_integer([:positive])}"
    rule = sample_rule(predicate_name)

    :ok = Catalog.admit_entry(:hub, rule, nil)

    conn = :get |> conn("/hub/search?q=#{predicate_name}") |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert conn.resp_body =~ predicate_name
  end

  test "GET /hub/entries/:node_id fetches a specific entry by its blank-node id, with no auth token" do
    predicate_name = "discoveryfetch#{System.unique_integer([:positive])}"
    rule = sample_rule(predicate_name)

    :ok = Catalog.admit_entry(:hub, rule, nil)
    {:ok, entries} = Catalog.list_entries(:hub)
    {node, ^rule} = Enum.find(entries, fn {_node, entry} -> entry == rule end)
    node_id = RDF.BlankNode.value(node)

    conn = :get |> conn("/hub/entries/#{node_id}") |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert conn.resp_body =~ predicate_name
  end

  test "GET /hub/entries/:node_id returns 404 for an id that was never admitted" do
    conn = :get |> conn("/hub/entries/nonexistent-node-id") |> RiptideWeb.Endpoint.call(@opts)
    assert conn.status == 404
  end
end
