defmodule Riptide.Derivation.MatcherGoldenCaseTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.{Matcher, Parser}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  test "a Rule joins facts that originated from separate, independently-built graphs" do
    {:ok, rule} = Parser.decode("colleague(X, Y) :- worksAt(X, Org), worksAt(Y, Org).")

    # Each of these stands in for one Riptide stream's current state — a
    # real caller (6d-i) would fold each stream's own event log into one
    # of these graphs independently, with no shared context between them.
    alice_stream_graph = RDF.Graph.new([{t("alice"), rel("worksAt"), t("acme")}])
    bob_stream_graph = RDF.Graph.new([{t("bob"), rel("worksAt"), t("acme")}])
    carol_stream_graph = RDF.Graph.new([{t("carol"), rel("worksAt"), t("globex")}])

    merged_graph =
      RDF.Graph.new()
      |> RDF.Graph.add(alice_stream_graph)
      |> RDF.Graph.add(bob_stream_graph)
      |> RDF.Graph.add(carol_stream_graph)

    assert {:ok, triples} = Matcher.evaluate(rule, merged_graph)

    # alice and bob share "acme" (from two different origin graphs) and
    # therefore join with each other, plus each with themselves; carol's
    # "globex" has no other member, so she only joins reflexively with
    # herself. Confirms the join binds a shared variable across facts that
    # came from different graphs, not just within one.
    assert MapSet.new(triples) ==
             MapSet.new([
               {t("alice"), rel("colleague"), t("alice")},
               {t("alice"), rel("colleague"), t("bob")},
               {t("bob"), rel("colleague"), t("alice")},
               {t("bob"), rel("colleague"), t("bob")},
               {t("carol"), rel("colleague"), t("carol")}
             ])
  end
end
