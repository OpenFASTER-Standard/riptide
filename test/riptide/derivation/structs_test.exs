defmodule Riptide.Derivation.StructsTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}
  alias Riptide.Derivation.{Rule, Signature, Var}

  test "Var carries a name" do
    assert %Var{name: "Svc"} == %Var{name: "Svc"}
  end

  test "Signature carries name, parameters, reads, produces" do
    sig = %Signature{
      name: RDF.iri("urn:riptide:relation:deployed"),
      parameters: [%Var{name: "Svc"}, %Var{name: "Result"}],
      reads: [RDF.iri("urn:riptide:relation:pendingDeploy")],
      produces: [RDF.iri("urn:riptide:relation:deployed")]
    }

    assert sig.name == RDF.iri("urn:riptide:relation:deployed")
    assert sig.parameters == [%Var{name: "Svc"}, %Var{name: "Result"}]
  end

  test "Literal.FactPattern carries a predicate and args" do
    literal = %FactPattern{
      predicate: RDF.iri("urn:riptide:relation:pendingDeploy"),
      args: [%Var{name: "Svc"}, %Var{name: "Target"}]
    }

    assert literal.predicate == RDF.iri("urn:riptide:relation:pendingDeploy")
    assert literal.args == [%Var{name: "Svc"}, %Var{name: "Target"}]
  end

  test "Literal.CapabilityReference carries a capability, args, and result" do
    literal = %CapabilityReference{
      capability: RDF.iri("urn:riptide:capability:deployService"),
      args: [%Var{name: "Svc"}, %Var{name: "Target"}],
      result: %Var{name: "Outcome"}
    }

    assert literal.capability == RDF.iri("urn:riptide:capability:deployService")
    assert literal.result == %Var{name: "Outcome"}
  end

  test "Literal.RuleReference carries a rule, args, and result" do
    literal = %RuleReference{
      rule: RDF.iri("urn:riptide:rule:notifyTeam"),
      args: [%Var{name: "Svc"}, %Var{name: "Outcome"}],
      result: %Var{name: "Result"}
    }

    assert literal.rule == RDF.iri("urn:riptide:rule:notifyTeam")
    assert literal.result == %Var{name: "Result"}
  end

  test "Rule carries a signature, head, and body" do
    head = %FactPattern{
      predicate: RDF.iri("urn:riptide:relation:deployed"),
      args: [%Var{name: "Svc"}, %Var{name: "Result"}]
    }

    body = [
      %FactPattern{
        predicate: RDF.iri("urn:riptide:relation:pendingDeploy"),
        args: [%Var{name: "Svc"}, %Var{name: "Target"}]
      }
    ]

    rule = %Rule{
      signature: %Signature{
        name: head.predicate,
        parameters: head.args,
        reads: [],
        produces: [head.predicate]
      },
      head: head,
      body: body
    }

    assert rule.head == head
    assert rule.body == body
  end
end
