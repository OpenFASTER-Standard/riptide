defmodule Riptide.Accounts.RDFCodec do
  @moduledoc """
  Reifies a `Riptide.Accounts.Account` as RDF triples and reads it back,
  following the exact same reification style
  `Riptide.Derivation.CapabilityCatalogRDFCodec` already established.
  """

  alias Riptide.Accounts.Account

  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_account RDF.iri("urn:riptide:vocab:Account")
  @riptide_username RDF.iri("urn:riptide:vocab:username")
  @riptide_password_hash_sha256 RDF.iri("urn:riptide:vocab:passwordHashSha256")
  @riptide_account_subject RDF.iri("urn:riptide:vocab:accountSubject")

  @spec to_rdf(Account.t()) :: {RDF.BlankNode.t(), RDF.Graph.t()}
  def to_rdf(%Account{} = account) do
    node = RDF.BlankNode.new()

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add({node, @rdf_type, @riptide_account})
      |> RDF.Graph.add({node, @riptide_username, RDF.literal(account.username)})
      |> RDF.Graph.add(
        {node, @riptide_password_hash_sha256, RDF.literal(account.password_hash_sha256)}
      )
      |> RDF.Graph.add({node, @riptide_account_subject, RDF.literal(account.sub)})

    {node, graph}
  end

  @spec from_rdf(RDF.Resource.t(), RDF.Graph.t()) :: Account.t()
  def from_rdf(node, graph) do
    description = RDF.Graph.get(graph, node)

    %Account{
      username: description |> RDF.Description.first(@riptide_username) |> RDF.Literal.value(),
      password_hash_sha256:
        description
        |> RDF.Description.first(@riptide_password_hash_sha256)
        |> RDF.Literal.value(),
      sub: description |> RDF.Description.first(@riptide_account_subject) |> RDF.Literal.value()
    }
  end
end
