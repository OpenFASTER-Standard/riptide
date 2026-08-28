defmodule Riptide.Derivation.RuleRDFCodecTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.{Parser, RuleRDFCodec}

  @sp_triple_pattern RDF.iri("http://spinrdf.org/sp#TriplePattern")
  @sp_subject RDF.iri("http://spinrdf.org/sp#subject")
  @sp_predicate RDF.iri("http://spinrdf.org/sp#predicate")
  @sp_var_name RDF.iri("http://spinrdf.org/sp#varName")
  @riptide_rule RDF.iri("urn:riptide:vocab:Rule")
  @riptide_capability_reference RDF.iri("urn:riptide:vocab:CapabilityReference")
  @riptide_rule_reference RDF.iri("urn:riptide:vocab:RuleReference")
  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")

  test "to_rdf/1 asserts the rule node's rdf:type" do
    {:ok, rule} = Parser.decode("deployed(Svc, Result) :- pendingDeploy(Svc, Result).")

    {node, graph} = RuleRDFCodec.to_rdf(rule)

    assert RDF.Graph.get(graph, node) |> RDF.Description.first(@rdf_type) == @riptide_rule
  end

  test "to_rdf/1 reifies a fact-pattern literal as an sp:TriplePattern" do
    {:ok, rule} = Parser.decode("deployed(Svc, Result) :- pendingDeploy(Svc, Result).")

    {_node, graph} = RuleRDFCodec.to_rdf(rule)

    triple_pattern_nodes =
      graph
      |> RDF.Graph.subjects()
      |> Enum.filter(fn s ->
        RDF.Graph.get(graph, s) |> RDF.Description.first(@rdf_type) == @sp_triple_pattern
      end)

    assert length(triple_pattern_nodes) == 1

    [tp_node] = triple_pattern_nodes
    tp = RDF.Graph.get(graph, tp_node)

    assert tp |> RDF.Description.first(@sp_predicate) ==
             RDF.iri("urn:riptide:relation:pendingDeploy")

    subject_var_node = RDF.Description.first(tp, @sp_subject)

    assert RDF.Graph.get(graph, subject_var_node) |> RDF.Description.first(@sp_var_name) ==
             RDF.literal("Svc")
  end

  test "to_rdf/1 reifies a capability-reference literal" do
    {:ok, rule} =
      Parser.decode(
        "deployed(Svc, Outcome) :- pendingDeploy(Svc, Target), capability(deployService, Svc, Target, Outcome)."
      )

    {_node, graph} = RuleRDFCodec.to_rdf(rule)

    cap_nodes =
      graph
      |> RDF.Graph.subjects()
      |> Enum.filter(fn s ->
        RDF.Graph.get(graph, s) |> RDF.Description.first(@rdf_type) ==
          @riptide_capability_reference
      end)

    assert length(cap_nodes) == 1
  end

  test "to_rdf/1 reifies a rule-reference literal" do
    {:ok, rule} =
      Parser.decode(
        "notified(Svc, Result) :- capability(deployService, Svc, Svc, Outcome), rule(notifyTeam, Svc, Outcome, Result)."
      )

    {_node, graph} = RuleRDFCodec.to_rdf(rule)

    rule_ref_nodes =
      graph
      |> RDF.Graph.subjects()
      |> Enum.filter(fn s ->
        RDF.Graph.get(graph, s) |> RDF.Description.first(@rdf_type) == @riptide_rule_reference
      end)

    assert length(rule_ref_nodes) == 1
  end

  test "to_rdf/1 raises a clear error for a fact-pattern literal with the wrong arity" do
    alias Riptide.Derivation.Literal.FactPattern
    alias Riptide.Derivation.{Rule, Signature, Var}

    bad_head = %FactPattern{
      predicate: RDF.iri("urn:riptide:relation:bad"),
      args: [%Var{name: "X"}]
    }

    rule = %Rule{
      signature: %Signature{
        name: bad_head.predicate,
        parameters: bad_head.args,
        reads: [],
        produces: [bad_head.predicate]
      },
      head: bad_head,
      body: [bad_head]
    }

    assert_raise ArgumentError, ~r/exactly 2 args/, fn -> RuleRDFCodec.to_rdf(rule) end
  end

  describe "from_rdf/2 — inverse of to_rdf/1" do
    test "round-trips a fact-pattern-only rule" do
      {:ok, rule} = Parser.decode("deployed(Svc, Result) :- pendingDeploy(Svc, Result).")

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      assert RuleRDFCodec.from_rdf(node, graph) == rule
    end

    test "round-trips a rule with multiple conjoined fact-pattern literals" do
      {:ok, rule} = Parser.decode("path(X, Y) :- edge(X, Z), path(Z, Y).")

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      assert RuleRDFCodec.from_rdf(node, graph) == rule
    end

    test "round-trips a rule with a capability-reference literal" do
      {:ok, rule} =
        Parser.decode(
          "deployed(Svc, Outcome) :- pendingDeploy(Svc, Target), capability(deployService, Svc, Target, Outcome)."
        )

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      assert RuleRDFCodec.from_rdf(node, graph) == rule
    end

    test "round-trips a rule with a rule-reference literal" do
      {:ok, rule} =
        Parser.decode(
          "notified(Svc, Result) :- capability(deployService, Svc, Svc, Outcome), rule(notifyTeam, Svc, Outcome, Result)."
        )

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      assert RuleRDFCodec.from_rdf(node, graph) == rule
    end

    test "round-trips the walking-skeleton worked example with all three literal kinds" do
      {:ok, rule} =
        Parser.decode("""
        deployed(Svc, Result) :-
            pendingDeploy(Svc, Target),
            capability(deployService, Svc, Target, Outcome),
            rule(notifyTeam, Svc, Outcome, Result).
        """)

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      assert RuleRDFCodec.from_rdf(node, graph) == rule
    end

    test "round-trips a recursive rule" do
      {:ok, rule} = Parser.decode("path(X, Y) :- edge(X, Y).")

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      assert RuleRDFCodec.from_rdf(node, graph) == rule
    end

    test "round-trips a rule with a string constant" do
      {:ok, rule} = Parser.decode(~s|status(Svc, "healthy") :- pendingDeploy(Svc, "healthy").|)

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      assert RuleRDFCodec.from_rdf(node, graph) == rule
    end

    test "round-trips a rule with a bracketed-IRI constant argument" do
      {:ok, rule} =
        Parser.decode(
          ~s|status(Svc, <http://example.org/Healthy>) :- pendingDeploy(Svc, Result).|
        )

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      assert RuleRDFCodec.from_rdf(node, graph) == rule
    end

    test "round-trips signature.reads in the ORIGINAL body order, not re-sorted" do
      # "zebra" then "apple" is not alphabetically sorted — this catches
      # `RDF.Description.get/3`'s own (non-insertion-order) ordering being
      # used to decode `reads`, which would silently re-sort to
      # [apple, zebra].
      {:ok, rule} = Parser.decode("h(A, B) :- zebra(A, X), apple(X, B).")

      assert rule.signature.reads == [
               RDF.iri("urn:riptide:relation:zebra"),
               RDF.iri("urn:riptide:relation:apple")
             ]

      {node, graph} = RuleRDFCodec.to_rdf(rule)

      decoded = RuleRDFCodec.from_rdf(node, graph)

      assert decoded.signature.reads == rule.signature.reads
      assert decoded == rule
    end
  end
end
