defmodule Riptide.Derivation.ParserTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{Parser, Var}

  describe "decode/1 — fact-pattern-only rules" do
    test "parses a rule with a single body literal" do
      text = "deployed(Svc, Result) :- pendingDeploy(Svc, Result)."

      assert {:ok, rule} = Parser.decode(text)

      assert rule.head == %FactPattern{
               predicate: RDF.iri("urn:riptide:relation:deployed"),
               args: [%Var{name: "Svc"}, %Var{name: "Result"}]
             }

      assert rule.body == [
               %FactPattern{
                 predicate: RDF.iri("urn:riptide:relation:pendingDeploy"),
                 args: [%Var{name: "Svc"}, %Var{name: "Result"}]
               }
             ]
    end

    test "parses a rule with multiple conjoined body literals" do
      text = "path(X, Y) :- edge(X, Z), path(Z, Y)."

      assert {:ok, rule} = Parser.decode(text)
      assert length(rule.body) == 2

      assert Enum.at(rule.body, 0) == %FactPattern{
               predicate: RDF.iri("urn:riptide:relation:edge"),
               args: [%Var{name: "X"}, %Var{name: "Z"}]
             }

      assert Enum.at(rule.body, 1) == %FactPattern{
               predicate: RDF.iri("urn:riptide:relation:path"),
               args: [%Var{name: "Z"}, %Var{name: "Y"}]
             }
    end

    test "recursive rules parse fine — the head's predicate may match a body literal's" do
      text = "path(X, Y) :- edge(X, Y)."

      assert {:ok, rule} = Parser.decode(text)
      assert rule.head.predicate == RDF.iri("urn:riptide:relation:path")
    end

    test "an explicit bracketed IRI may be used as a fact-pattern predicate" do
      text =
        "<http://www.w3.org/ns/ldp#contains>(Container, Member) :- pendingDeploy(Container, Member)."

      assert {:ok, rule} = Parser.decode(text)
      assert rule.head.predicate == RDF.iri("http://www.w3.org/ns/ldp#contains")
    end

    test "string constants are supported as args" do
      text = ~s|status(Svc, "healthy") :- pendingDeploy(Svc, "healthy").|

      assert {:ok, rule} = Parser.decode(text)
      assert rule.head.args == [%Var{name: "Svc"}, RDF.literal("healthy")]
    end

    test "returns an error tuple, not a crash, on malformed input" do
      assert {:error, _reason} = Parser.decode("this is not a rule")
    end

    test "decode/1 does not permanently mutate the calling process's own heap cap" do
      # Regression test: decode/1 used to call `Process.flag(:max_heap_size, ...)`
      # directly on the calling process, which stuck for that process's entire
      # remaining lifetime. It now isolates the cap inside a throwaway Task, so
      # the caller's own flag must be unchanged after a call, win or lose.
      {:max_heap_size, before} = Process.info(self(), :max_heap_size)

      assert {:ok, _rule} = Parser.decode("deployed(Svc, Result) :- pendingDeploy(Svc, Result).")
      assert {:error, _reason} = Parser.decode("this is not a rule")

      assert {:max_heap_size, ^before} = Process.info(self(), :max_heap_size)
    end

    test "the derived Signature reflects the head and body" do
      text = "deployed(Svc, Result) :- pendingDeploy(Svc, Target), other(Target, Result)."

      assert {:ok, rule} = Parser.decode(text)
      assert rule.signature.name == RDF.iri("urn:riptide:relation:deployed")
      assert rule.signature.parameters == [%Var{name: "Svc"}, %Var{name: "Result"}]
      assert rule.signature.produces == [RDF.iri("urn:riptide:relation:deployed")]

      assert Enum.sort(rule.signature.reads) ==
               Enum.sort([
                 RDF.iri("urn:riptide:relation:pendingDeploy"),
                 RDF.iri("urn:riptide:relation:other")
               ])
    end
  end

  describe "decode/1 — capability(...) and rule(...) literals" do
    alias Riptide.Derivation.Literal.{CapabilityReference, RuleReference}

    test "parses a capability-reference literal, with the last arg as result" do
      text =
        "deployed(Svc, Outcome) :- pendingDeploy(Svc, Target), capability(deployService, Svc, Target, Outcome)."

      assert {:ok, rule} = Parser.decode(text)
      assert length(rule.body) == 2

      assert Enum.at(rule.body, 1) == %CapabilityReference{
               capability: RDF.iri("urn:riptide:capability:deployService"),
               args: [%Var{name: "Svc"}, %Var{name: "Target"}],
               result: %Var{name: "Outcome"}
             }
    end

    test "parses a rule-reference literal, with the last arg as result" do
      text =
        "notified(Svc, Result) :- capability(deployService, Svc, Svc, Outcome), rule(notifyTeam, Svc, Outcome, Result)."

      assert {:ok, rule} = Parser.decode(text)

      assert Enum.at(rule.body, 1) == %RuleReference{
               rule: RDF.iri("urn:riptide:rule:notifyTeam"),
               args: [%Var{name: "Svc"}, %Var{name: "Outcome"}],
               result: %Var{name: "Result"}
             }
    end

    test "the walking-skeleton worked example (design spec §1) parses with all three literal kinds" do
      text = """
      deployed(Svc, Result) :-
          pendingDeploy(Svc, Target),
          capability(deployService, Svc, Target, Outcome),
          rule(notifyTeam, Svc, Outcome, Result).
      """

      assert {:ok, rule} = Parser.decode(text)
      assert length(rule.body) == 3
      assert %FactPattern{} = Enum.at(rule.body, 0)
      assert %CapabilityReference{} = Enum.at(rule.body, 1)
      assert %RuleReference{} = Enum.at(rule.body, 2)
    end

    test "an identifier that merely starts with \"capability\" is still an ordinary fact-pattern literal" do
      text = "x(A, B) :- capabilityFoo(A, B)."

      assert {:ok, rule} = Parser.decode(text)
      assert %FactPattern{predicate: predicate} = hd(rule.body)
      assert predicate == RDF.iri("urn:riptide:relation:capabilityFoo")
    end

    test "the derived Signature's reads only includes fact-pattern predicates, not capability/rule names" do
      text =
        "deployed(Svc, Result) :- pendingDeploy(Svc, Target), capability(deployService, Svc, Target, Result)."

      assert {:ok, rule} = Parser.decode(text)
      assert rule.signature.reads == [RDF.iri("urn:riptide:relation:pendingDeploy")]
    end

    test "a capability literal with no arguments at all (missing the mandatory result) is a clean parse error" do
      text = "x(A, B) :- capability(deployService)."

      assert {:error, _reason} = Parser.decode(text)
    end

    test "a rule literal with no arguments at all (missing the mandatory result) is a clean parse error" do
      text = "x(A, B) :- rule(notifyTeam)."

      assert {:error, _reason} = Parser.decode(text)
    end
  end
end
