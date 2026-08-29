defmodule Riptide.Derivation.DedupGate.PendingReviewTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.DedupGate.PendingReview
  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{Rule, Signature}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  defp candidate_rule do
    head = %FactPattern{predicate: rel("greeted"), args: [t("alice"), RDF.literal("hi")]}

    %Rule{
      signature: %Signature{
        name: head.predicate,
        parameters: [],
        reads: [],
        produces: [head.predicate]
      },
      head: head,
      body: []
    }
  end

  test "round-trips an :admit PendingReview with passing fidelity evidence, no replaces" do
    pending_review = %PendingReview{
      kind: :admit,
      candidate: candidate_rule(),
      fidelity_evidence: [:fidelity_pass, :fidelity_pass],
      replaces: nil
    }

    {node, graph} = PendingReview.to_rdf(pending_review)

    assert PendingReview.from_rdf(node, graph) == pending_review
  end

  test "round-trips a :merge PendingReview with mixed fidelity evidence and a replaces node" do
    replaces_node = RDF.BlankNode.new()
    original_reason = {:capability_mismatch, t("cap"), "a", "b"}

    pending_review = %PendingReview{
      kind: :merge,
      candidate: candidate_rule(),
      fidelity_evidence: [:fidelity_pass, {:fidelity_fail, original_reason}],
      replaces: replaces_node
    }

    {node, graph} = PendingReview.to_rdf(pending_review)

    # The failure reason is encoded via inspect/1 (design spec §6, deliberate
    # — the reviewer needs to *see* why a check failed, not programmatically
    # parse it) so it round-trips as the inspected string, not the original
    # term.
    assert PendingReview.from_rdf(node, graph) == %{
             pending_review
             | fidelity_evidence: [:fidelity_pass, {:fidelity_fail, inspect(original_reason)}]
           }
  end
end
