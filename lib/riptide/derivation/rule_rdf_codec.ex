defmodule Riptide.Derivation.RuleRDFCodec do
  @moduledoc """
  Reifies a `Riptide.Derivation.Rule` as RDF triples ("Rules are Facts",
  design spec §2/§5) and reads it back. Reuses SPIN's `sp:` vocabulary for
  fact-pattern literals (the same triple-pattern shape SPIN already
  solved) and mints `urn:riptide:vocab:` terms for capability-reference/
  rule-reference literals, which no existing vocabulary covers.

  Variable blank nodes are not deduplicated across occurrences by
  `to_rdf/1` — round-trip correctness only requires reading back the same
  `Var.name`, not referential graph identity (design spec Global
  Constraints).
  """

  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}
  alias Riptide.Derivation.{Rule, Signature, Var}

  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @sp_triple_pattern RDF.iri("http://spinrdf.org/sp#TriplePattern")
  # SPIN's own sibling class of sp:TriplePattern (both are subclasses of
  # sp:Triple, not one a subclass of the other) used for CONSTRUCT-template
  # triples (`sp:Construct`'s `sp:templates`) rather than WHERE-clause match
  # patterns (`sp:where`) — exactly the Head-vs-Body distinction a Rule's
  # `head` (what to assert) vs. `body` (what to match) draws. Reusing it keeps
  # a rule's `head` fact-pattern out of the `sp:TriplePattern`-typed node count
  # that `from_rdf/2` (Task 5) and callers use to enumerate Body literals.
  @sp_triple_template RDF.iri("http://spinrdf.org/sp#TripleTemplate")
  @sp_subject RDF.iri("http://spinrdf.org/sp#subject")
  @sp_predicate RDF.iri("http://spinrdf.org/sp#predicate")
  @sp_object RDF.iri("http://spinrdf.org/sp#object")
  @sp_var_name RDF.iri("http://spinrdf.org/sp#varName")

  @riptide_rule RDF.iri("urn:riptide:vocab:Rule")
  @riptide_signature RDF.iri("urn:riptide:vocab:signature")
  @riptide_head RDF.iri("urn:riptide:vocab:head")
  @riptide_body RDF.iri("urn:riptide:vocab:body")
  @riptide_capability_reference RDF.iri("urn:riptide:vocab:CapabilityReference")
  @riptide_capability RDF.iri("urn:riptide:vocab:capability")
  @riptide_rule_reference RDF.iri("urn:riptide:vocab:RuleReference")
  @riptide_rule_prop RDF.iri("urn:riptide:vocab:rule")
  @riptide_args RDF.iri("urn:riptide:vocab:args")
  @riptide_result RDF.iri("urn:riptide:vocab:result")
  @riptide_name RDF.iri("urn:riptide:vocab:name")
  @riptide_parameters RDF.iri("urn:riptide:vocab:parameters")
  @riptide_reads RDF.iri("urn:riptide:vocab:reads")
  @riptide_produces RDF.iri("urn:riptide:vocab:produces")

  @doc "See moduledoc. Returns the Rule's own (blank) node plus the graph fragment reifying it."
  @spec to_rdf(Rule.t()) :: {RDF.BlankNode.t(), RDF.Graph.t()}
  def to_rdf(%Rule{} = rule) do
    node = RDF.BlankNode.new()
    {sig_node, sig_graph} = encode_signature(rule.signature)
    {head_node, head_graph} = encode_head(rule.head)
    {body_head, body_graph} = encode_body(rule.body)

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add(sig_graph)
      |> RDF.Graph.add(head_graph)
      |> RDF.Graph.add(body_graph)
      |> RDF.Graph.add({node, @rdf_type, @riptide_rule})
      |> RDF.Graph.add({node, @riptide_signature, sig_node})
      |> RDF.Graph.add({node, @riptide_head, head_node})
      |> RDF.Graph.add({node, @riptide_body, body_head})

    {node, graph}
  end

  defp encode_signature(%Signature{} = sig) do
    node = RDF.BlankNode.new()
    {param_terms, params_graph} = encode_terms(sig.parameters)
    params_list = RDF.List.from(param_terms)

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add(params_graph)
      |> RDF.Graph.add(params_list.graph)
      |> RDF.Graph.add({node, @riptide_name, sig.name})
      |> RDF.Graph.add({node, @riptide_parameters, params_list.head})
      |> RDF.Graph.add(Enum.map(sig.reads, &{node, @riptide_reads, &1}))
      |> RDF.Graph.add(Enum.map(sig.produces, &{node, @riptide_produces, &1}))

    {node, graph}
  end

  defp encode_body(literals) do
    {nodes, graph} =
      Enum.reduce(literals, {[], RDF.Graph.new()}, fn literal, {acc, graph} ->
        {node, literal_graph} = encode_literal(literal)
        {[node | acc], RDF.Graph.add(graph, literal_graph)}
      end)

    list = RDF.List.from(Enum.reverse(nodes))
    {list.head, RDF.Graph.add(graph, list.graph)}
  end

  # The Rule's own `head` (what to assert) — an `sp:TripleTemplate`, not an
  # `sp:TriplePattern`; see the `@sp_triple_template` module attribute for why.
  defp encode_head(%FactPattern{} = fact_pattern) do
    encode_triple_pattern_literal(fact_pattern, @sp_triple_template)
  end

  # A Body literal that happens to be a fact-pattern — an `sp:TriplePattern`
  # (what to match), per design spec §5 / Global Constraints.
  defp encode_literal(%FactPattern{} = fact_pattern) do
    encode_triple_pattern_literal(fact_pattern, @sp_triple_pattern)
  end

  defp encode_literal(%CapabilityReference{} = lit) do
    encode_call_literal(
      lit.capability,
      lit.args,
      lit.result,
      @riptide_capability_reference,
      @riptide_capability
    )
  end

  defp encode_literal(%RuleReference{} = lit) do
    encode_call_literal(
      lit.rule,
      lit.args,
      lit.result,
      @riptide_rule_reference,
      @riptide_rule_prop
    )
  end

  defp encode_triple_pattern_literal(
         %FactPattern{predicate: predicate, args: [subject, object]},
         type_iri
       ) do
    node = RDF.BlankNode.new()
    {subject_term, subject_graph} = encode_term(subject)
    {object_term, object_graph} = encode_term(object)

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add(subject_graph)
      |> RDF.Graph.add(object_graph)
      |> RDF.Graph.add({node, @rdf_type, type_iri})
      |> RDF.Graph.add({node, @sp_subject, subject_term})
      |> RDF.Graph.add({node, @sp_predicate, predicate})
      |> RDF.Graph.add({node, @sp_object, object_term})

    {node, graph}
  end

  defp encode_triple_pattern_literal(%FactPattern{args: args}, _type_iri) do
    raise ArgumentError,
          "fact-pattern literals must have exactly 2 args (subject, object) to reify as an " <>
            "sp:TriplePattern — got #{length(args)}"
  end

  defp encode_call_literal(target, args, result, type_iri, target_predicate) do
    node = RDF.BlankNode.new()
    {args_terms, args_graph} = encode_terms(args)
    {result_term, result_graph} = encode_term(result)
    args_list = RDF.List.from(args_terms)

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add(args_graph)
      |> RDF.Graph.add(result_graph)
      |> RDF.Graph.add(args_list.graph)
      |> RDF.Graph.add({node, @rdf_type, type_iri})
      |> RDF.Graph.add({node, target_predicate, target})
      |> RDF.Graph.add({node, @riptide_args, args_list.head})
      |> RDF.Graph.add({node, @riptide_result, result_term})

    {node, graph}
  end

  defp encode_terms(terms) do
    {reversed, graph} =
      Enum.reduce(terms, {[], RDF.Graph.new()}, fn term, {acc, graph} ->
        {encoded, term_graph} = encode_term(term)
        {[encoded | acc], RDF.Graph.add(graph, term_graph)}
      end)

    {Enum.reverse(reversed), graph}
  end

  defp encode_term(%Var{name: name}) do
    node = RDF.BlankNode.new()
    {node, RDF.Graph.new() |> RDF.Graph.add({node, @sp_var_name, RDF.literal(name)})}
  end

  defp encode_term(term), do: {term, RDF.Graph.new()}

  @doc "See moduledoc. The inverse of `to_rdf/1`."
  @spec from_rdf(RDF.Resource.t(), RDF.Graph.t()) :: Rule.t()
  def from_rdf(node, graph) do
    description = RDF.Graph.get(graph, node)
    sig_node = RDF.Description.first(description, @riptide_signature)
    head_node = RDF.Description.first(description, @riptide_head)
    body_head = RDF.Description.first(description, @riptide_body)

    %Rule{
      signature: decode_signature(sig_node, graph),
      head: decode_literal(head_node, graph),
      body:
        RDF.List.new(body_head, graph)
        |> RDF.List.values()
        |> Enum.map(&decode_literal(&1, graph))
    }
  end

  defp decode_signature(node, graph) do
    description = RDF.Graph.get(graph, node)
    params_head = RDF.Description.first(description, @riptide_parameters)

    %Signature{
      name: RDF.Description.first(description, @riptide_name),
      parameters:
        RDF.List.new(params_head, graph)
        |> RDF.List.values()
        |> Enum.map(&decode_term(&1, graph)),
      reads: RDF.Description.get(description, @riptide_reads, []),
      produces: RDF.Description.get(description, @riptide_produces, [])
    }
  end

  # A rule's `head` is reified as `sp:TripleTemplate` (see `@sp_triple_template`)
  # while Body fact-pattern literals are reified as `sp:TriplePattern` — siblings
  # under `sp:Triple` carrying the same `sp:subject`/`sp:predicate`/`sp:object`
  # properties, so both decode to the identical `%FactPattern{}` shape here.
  defp decode_literal(node, graph) do
    description = RDF.Graph.get(graph, node)

    case RDF.Description.first(description, @rdf_type) do
      type when type in [@sp_triple_pattern, @sp_triple_template] ->
        %FactPattern{
          predicate: RDF.Description.first(description, @sp_predicate),
          args: [
            decode_term(RDF.Description.first(description, @sp_subject), graph),
            decode_term(RDF.Description.first(description, @sp_object), graph)
          ]
        }

      @riptide_capability_reference ->
        %CapabilityReference{
          capability: RDF.Description.first(description, @riptide_capability),
          args: decode_args(description, graph),
          result: decode_term(RDF.Description.first(description, @riptide_result), graph)
        }

      @riptide_rule_reference ->
        %RuleReference{
          rule: RDF.Description.first(description, @riptide_rule_prop),
          args: decode_args(description, graph),
          result: decode_term(RDF.Description.first(description, @riptide_result), graph)
        }
    end
  end

  defp decode_args(description, graph) do
    args_head = RDF.Description.first(description, @riptide_args)

    RDF.List.new(args_head, graph)
    |> RDF.List.values()
    |> Enum.map(&decode_term(&1, graph))
  end

  defp decode_term(%RDF.BlankNode{} = node, graph) do
    case RDF.Description.first(RDF.Graph.get(graph, node), @sp_var_name) do
      nil -> node
      name_literal -> %Var{name: RDF.Literal.value(name_literal)}
    end
  end

  defp decode_term(term, _graph), do: term
end
