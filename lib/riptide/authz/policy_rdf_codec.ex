defmodule Riptide.Authz.PolicyRDFCodec do
  @moduledoc """
  Reifies a `Riptide.Authz.Policy` (plus the `path_prefix` it's stored under) as RDF triples and reads
  it back — same reification style `Riptide.Accounts.RDFCodec` already established, extended with a
  `path_prefix` field since a Policy's storage key (its path_prefix) travels with it now that policies
  are ordinary per-tenant facts rather than entries in a `%{path_prefix => [policy]}` map (design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.3).
  """

  alias Riptide.Authz.Policy

  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_policy RDF.iri("urn:riptide:vocab:Policy")
  @riptide_path_prefix RDF.iri("urn:riptide:vocab:policyPathPrefix")
  @riptide_effect RDF.iri("urn:riptide:vocab:policyEffect")
  @riptide_mode RDF.iri("urn:riptide:vocab:policyMode")
  @riptide_matcher_type RDF.iri("urn:riptide:vocab:policyMatcherType")
  @riptide_matcher_subject RDF.iri("urn:riptide:vocab:policyMatcherSubject")

  @spec to_rdf(Policy.t(), [String.t()]) :: {RDF.BlankNode.t(), RDF.Graph.t()}
  def to_rdf(%Policy{} = policy, path_prefix) do
    node = RDF.BlankNode.new()
    prefix_list = RDF.List.from(Enum.map(path_prefix, &RDF.literal/1))

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add(prefix_list.graph)
      |> RDF.Graph.add({node, @rdf_type, @riptide_policy})
      |> RDF.Graph.add({node, @riptide_path_prefix, prefix_list.head})
      |> RDF.Graph.add({node, @riptide_effect, RDF.literal(Atom.to_string(policy.effect))})
      |> add_modes(node, policy.modes)
      |> add_matcher(node, policy.matcher)

    {node, graph}
  end

  defp add_modes(graph, node, modes) do
    Enum.reduce(modes, graph, fn mode, graph ->
      RDF.Graph.add(graph, {node, @riptide_mode, RDF.literal(Atom.to_string(mode))})
    end)
  end

  defp add_matcher(graph, node, :public) do
    RDF.Graph.add(graph, {node, @riptide_matcher_type, RDF.literal("public")})
  end

  defp add_matcher(graph, node, :authenticated) do
    RDF.Graph.add(graph, {node, @riptide_matcher_type, RDF.literal("authenticated")})
  end

  defp add_matcher(graph, node, {:agent, subject}) do
    graph
    |> RDF.Graph.add({node, @riptide_matcher_type, RDF.literal("agent")})
    |> RDF.Graph.add({node, @riptide_matcher_subject, RDF.literal(subject)})
  end

  @spec from_rdf(RDF.Resource.t(), RDF.Graph.t()) :: {[String.t()], Policy.t()}
  def from_rdf(node, graph) do
    description = RDF.Graph.get(graph, node)
    prefix_head = RDF.Description.first(description, @riptide_path_prefix)
    path_prefix = decode_prefix(prefix_head, graph)

    effect =
      description
      |> RDF.Description.first(@riptide_effect)
      |> RDF.Literal.value()
      |> String.to_existing_atom()

    modes =
      description
      |> RDF.Description.get(@riptide_mode, [])
      |> Enum.map(&(&1 |> RDF.Literal.value() |> String.to_existing_atom()))

    matcher = decode_matcher(description)

    {path_prefix, %Policy{effect: effect, modes: modes, matcher: matcher}}
  end

  # An empty path_prefix encodes to rdf:nil (the well-known empty-list sentinel via RDF.List.from([])),
  # which has no triples describing it — RDF.Graph.get/2 returns nil, the same shape
  # DedupGate.PendingReview.decode_evidence/2 already documents and handles for its own empty-list case.
  defp decode_prefix(head, graph) do
    case RDF.Graph.get(graph, head) do
      nil ->
        []

      _description ->
        head |> RDF.List.new(graph) |> RDF.List.values() |> Enum.map(&RDF.Literal.value/1)
    end
  end

  defp decode_matcher(description) do
    case RDF.Description.first(description, @riptide_matcher_type) |> RDF.Literal.value() do
      "public" ->
        :public

      "authenticated" ->
        :authenticated

      "agent" ->
        subject =
          description |> RDF.Description.first(@riptide_matcher_subject) |> RDF.Literal.value()

        {:agent, subject}
    end
  end
end
