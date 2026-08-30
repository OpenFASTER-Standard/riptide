defmodule Riptide.Derivation.DedupGate.PendingReview do
  @moduledoc """
  A proposed Catalog change (`Admit` or `Merge`) awaiting human review, with
  6e-ii's fidelity evidence attached. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6e-iii-dedupgate-orchestration-design.md`
  §6.
  """

  alias Riptide.Derivation.{Rule, RuleRDFCodec}

  @enforce_keys [:kind, :candidate, :fidelity_evidence, :replaces]
  defstruct [:kind, :candidate, :fidelity_evidence, :replaces]

  @type kind :: :admit | :merge
  @type fidelity_evidence :: :fidelity_pass | {:fidelity_fail, term()}

  @type t :: %__MODULE__{
          kind: kind(),
          candidate: Rule.t(),
          fidelity_evidence: [fidelity_evidence()] | :not_applicable,
          replaces: RDF.BlankNode.t() | nil
        }

  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_pending_review RDF.iri("urn:riptide:vocab:PendingReview")
  @riptide_kind RDF.iri("urn:riptide:vocab:kind")
  @riptide_candidate RDF.iri("urn:riptide:vocab:candidate")
  @riptide_fidelity_evidence RDF.iri("urn:riptide:vocab:fidelityEvidence")
  @riptide_fidelity_not_applicable RDF.iri("urn:riptide:vocab:FidelityNotApplicable")
  @riptide_fidelity_status RDF.iri("urn:riptide:vocab:fidelityStatus")
  @riptide_fidelity_reason RDF.iri("urn:riptide:vocab:fidelityReason")
  @riptide_replaces RDF.iri("urn:riptide:vocab:replaces")

  @doc "See moduledoc. Returns the item's own (blank) node plus the graph fragment reifying it."
  @spec to_rdf(t()) :: {RDF.BlankNode.t(), RDF.Graph.t()}
  def to_rdf(%__MODULE__{} = pending_review) do
    node = RDF.BlankNode.new()
    {candidate_node, candidate_graph} = RuleRDFCodec.to_rdf(pending_review.candidate)
    {evidence_head, evidence_graph} = encode_evidence(pending_review.fidelity_evidence)

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add(candidate_graph)
      |> RDF.Graph.add(evidence_graph)
      |> RDF.Graph.add({node, @rdf_type, @riptide_pending_review})
      |> RDF.Graph.add({node, @riptide_kind, RDF.literal(Atom.to_string(pending_review.kind))})
      |> RDF.Graph.add({node, @riptide_candidate, candidate_node})
      |> RDF.Graph.add({node, @riptide_fidelity_evidence, evidence_head})
      |> maybe_add_replaces(node, pending_review.replaces)

    {node, graph}
  end

  defp maybe_add_replaces(graph, _node, nil), do: graph

  defp maybe_add_replaces(graph, node, replaces),
    do: RDF.Graph.add(graph, {node, @riptide_replaces, replaces})

  defp encode_evidence(:not_applicable) do
    node = RDF.BlankNode.new()
    {node, RDF.Graph.new() |> RDF.Graph.add({node, @rdf_type, @riptide_fidelity_not_applicable})}
  end

  defp encode_evidence(evidence_list) do
    {nodes, graph} =
      Enum.reduce(evidence_list, {[], RDF.Graph.new()}, fn evidence, {acc, graph} ->
        {node, evidence_graph} = encode_one_evidence(evidence)
        {[node | acc], RDF.Graph.add(graph, evidence_graph)}
      end)

    list = RDF.List.from(Enum.reverse(nodes))
    {list.head, RDF.Graph.add(graph, list.graph)}
  end

  defp encode_one_evidence(:fidelity_pass) do
    node = RDF.BlankNode.new()

    {node,
     RDF.Graph.new() |> RDF.Graph.add({node, @riptide_fidelity_status, RDF.literal("pass")})}
  end

  defp encode_one_evidence({:fidelity_fail, reason}) do
    node = RDF.BlankNode.new()

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add({node, @riptide_fidelity_status, RDF.literal("fail")})
      |> RDF.Graph.add({node, @riptide_fidelity_reason, RDF.literal(inspect(reason))})

    {node, graph}
  end

  @doc "See moduledoc. The inverse of `to_rdf/1`. Requires the item's own node to already be known."
  @spec from_rdf(RDF.Resource.t(), RDF.Graph.t()) :: t()
  def from_rdf(node, graph) do
    description = RDF.Graph.get(graph, node)

    # Safe: "admit"/"merge" are the only two values `to_rdf/1` ever writes,
    # and both atoms already exist in the atom table from this module's own
    # @type/struct usage above — never derived from untrusted input.
    kind =
      description
      |> RDF.Description.first(@riptide_kind)
      |> RDF.Literal.value()
      |> String.to_existing_atom()

    candidate_node = RDF.Description.first(description, @riptide_candidate)
    candidate = RuleRDFCodec.from_rdf(candidate_node, graph)
    evidence_head = RDF.Description.first(description, @riptide_fidelity_evidence)
    fidelity_evidence = decode_evidence(evidence_head, graph)

    replaces = RDF.Description.first(description, @riptide_replaces)

    %__MODULE__{
      kind: kind,
      candidate: candidate,
      fidelity_evidence: fidelity_evidence,
      replaces: replaces
    }
  end

  defp decode_evidence(node, graph) do
    description = RDF.Graph.get(graph, node)

    case RDF.Description.first(description, @rdf_type) do
      @riptide_fidelity_not_applicable ->
        :not_applicable

      _other ->
        RDF.List.new(node, graph)
        |> RDF.List.values()
        |> Enum.map(&decode_one_evidence(&1, graph))
    end
  end

  defp decode_one_evidence(node, graph) do
    description = RDF.Graph.get(graph, node)
    status = description |> RDF.Description.first(@riptide_fidelity_status) |> RDF.Literal.value()

    case status do
      "pass" ->
        :fidelity_pass

      "fail" ->
        reason =
          description |> RDF.Description.first(@riptide_fidelity_reason) |> RDF.Literal.value()

        {:fidelity_fail, reason}
    end
  end
end

defmodule Riptide.Derivation.DedupGate do
  @moduledoc """
  Catalog lookup, the `Reject`/`Merge`/`Admit` decision, and the human
  review workflow. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6e-iii-dedupgate-orchestration-design.md`.
  """

  alias Riptide.Derivation.{AntiUnifier, Catalog, GeneralizationFidelity, Rule, Var}
  alias Riptide.Derivation.DedupGate.PendingReview
  alias Riptide.Derivation.ExecuteInterpreter.Context

  @type candidates :: [{Rule.t(), AntiUnifier.substitution(), AntiUnifier.substitution()}]
  @type outcome ::
          {:rejected, reason :: term()}
          | {:fidelity_failed, [PendingReview.fidelity_evidence()]}
          | {:queued, RDF.BlankNode.t(), PendingReview.kind()}

  @spec propose(Catalog.scope(), Catalog.scope(), candidates(), RDF.Graph.t(), Context.t()) ::
          {:ok, [outcome()]} | {:error, term()}
  def propose(target_scope, review_scope, candidates, graph, context) do
    with {:ok, entries} <- Catalog.list_entries(target_scope) do
      {:ok, Enum.map(candidates, &propose_one(review_scope, &1, entries, graph, context))}
    end
  end

  defp propose_one(review_scope, {generalization, sub1, sub2}, entries, graph, context) do
    trace1 = AntiUnifier.substitute(generalization, sub1)
    trace2 = AntiUnifier.substitute(generalization, sub2)

    case classify(generalization, entries) do
      {:reject, reason} ->
        {:rejected, reason}

      {kind, replaces} ->
        finish_proposal(
          review_scope,
          generalization,
          kind,
          replaces,
          trace1,
          trace2,
          graph,
          context
        )
    end
  end

  defp finish_proposal(
         review_scope,
         generalization,
         kind,
         replaces,
         trace1,
         trace2,
         graph,
         context
       ) do
    case fidelity_evidence(trace1, trace2, graph, context) do
      {:ok, evidence} ->
        pending_review = %PendingReview{
          kind: kind,
          candidate: generalization,
          fidelity_evidence: evidence,
          replaces: replaces
        }

        {:ok, node} = Catalog.queue_pending_review(review_scope, pending_review)
        {:queued, node, kind}

      {:error, evidence} ->
        {:fidelity_failed, evidence}
    end
  end

  @spec propose_install(Catalog.scope(), Catalog.scope(), Rule.t()) ::
          {:ok, outcome()} | {:error, term()}
  def propose_install(target_scope, review_scope, %Rule{} = installed_rule) do
    with {:ok, entries} <- Catalog.list_entries(target_scope) do
      case classify(installed_rule, entries) do
        {:reject, reason} ->
          {:ok, {:rejected, reason}}

        {kind, replaces} ->
          pending_review = %PendingReview{
            kind: kind,
            candidate: installed_rule,
            fidelity_evidence: :not_applicable,
            replaces: replaces
          }

          {:ok, node} = Catalog.queue_pending_review(review_scope, pending_review)
          {:ok, {:queued, node, kind}}
      end
    end
  end

  defp classify(candidate, entries) do
    matching =
      Enum.filter(entries, fn {_node, entry} ->
        entry.head.predicate == candidate.head.predicate
      end)

    case Enum.find(matching, fn {_node, entry} -> entry_unchanged?(candidate, entry) end) do
      {_node, _entry} ->
        {:reject, :already_covered}

      nil ->
        case matching do
          [] -> {:admit, nil}
          [{node, _entry} | _rest] -> {:merge, node}
        end
    end
  end

  defp entry_unchanged?(candidate, entry) do
    case AntiUnifier.generalize(candidate, entry) do
      {:ok, results} ->
        Enum.any?(results, fn {_generalization, _sub_candidate, sub_entry} ->
          Enum.all?(Map.values(sub_entry), &match?(%Var{}, &1))
        end)

      {:error, :body_too_large} ->
        false
    end
  end

  defp fidelity_evidence(trace1, trace2, graph, context) do
    evidence =
      Enum.map([trace1, trace2], fn trace ->
        trace |> GeneralizationFidelity.check(graph, context) |> normalize_fidelity_result()
      end)

    if Enum.all?(evidence, &(&1 == :fidelity_pass)) do
      {:ok, evidence}
    else
      {:error, evidence}
    end
  end

  defp normalize_fidelity_result({:ok, :fidelity_pass}), do: :fidelity_pass
  defp normalize_fidelity_result({:ok, {:fidelity_fail, reason}}), do: {:fidelity_fail, reason}
  defp normalize_fidelity_result({:error, reason}), do: {:fidelity_fail, reason}

  @spec approve_review(Catalog.scope(), Catalog.scope(), RDF.BlankNode.t()) ::
          :ok | {:error, term()}
  def approve_review(target_scope, review_scope, node) do
    with {:ok, pending_reviews} <- Catalog.list_pending_reviews(review_scope),
         {_node, pending_review} <- List.keyfind(pending_reviews, node, 0, :not_found) do
      apply_approved(target_scope, review_scope, node, pending_review)
    else
      :not_found -> {:error, :not_found}
      error -> error
    end
  end

  defp apply_approved(
         target_scope,
         review_scope,
         node,
         %PendingReview{kind: :admit} = pending_review
       ) do
    :ok = Catalog.admit_entry(target_scope, pending_review.candidate, nil)
    Catalog.resolve_pending_review(review_scope, node, :approved)
  end

  defp apply_approved(
         target_scope,
         review_scope,
         node,
         %PendingReview{kind: :merge} = pending_review
       ) do
    :ok = Catalog.admit_entry(target_scope, pending_review.candidate, pending_review.replaces)
    :ok = Catalog.supersede_entry(target_scope, pending_review.replaces)
    Catalog.resolve_pending_review(review_scope, node, :approved)
  end

  @spec decline_review(Catalog.scope(), RDF.BlankNode.t()) :: :ok | {:error, term()}
  def decline_review(scope, node), do: Catalog.resolve_pending_review(scope, node, :declined)
end
