defmodule Riptide.Derivation.AntiUnifierTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.AntiUnifier
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern}
  alias Riptide.Derivation.{Rule, Signature, Var}

  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)
  defp cap(name), do: RDF.iri("urn:riptide:capability:" <> name)

  defp rule(head, body) do
    %Rule{
      signature: %Signature{
        name: head.predicate,
        parameters: head.args,
        reads: body |> Enum.filter(&match?(%FactPattern{}, &1)) |> Enum.map(& &1.predicate),
        produces: [head.predicate]
      },
      head: head,
      body: body
    }
  end

  # Every variable in the generalization must be a fresh "$au_" one — the
  # generalized Rule should never literally reuse either input's own
  # variable names, even where an input's own name happened to survive
  # unchanged by coincidence.
  defp all_generalization_vars?(%Rule{} = rule) do
    rule
    |> vars_in_rule()
    |> Enum.all?(&String.starts_with?(&1.name, "$au_"))
  end

  defp vars_in_rule(%Rule{head: head, body: body}) do
    [head | body]
    |> Enum.flat_map(fn
      %FactPattern{args: args} -> args
      %CapabilityReference{args: args, result: result} -> [result | args]
    end)
    |> Enum.filter(&match?(%Var{}, &1))
  end

  test "a simple unique lgg shares one generalization variable for a value recurring across head and body" do
    rule1 =
      rule(
        %FactPattern{
          predicate: rel("greeted"),
          args: [RDF.literal("alice"), %Var{name: "Result"}]
        },
        [
          %FactPattern{
            predicate: rel("pendingDeploy"),
            args: [RDF.literal("alice"), RDF.literal("v1")]
          },
          %CapabilityReference{
            capability: cap("deployService"),
            args: [RDF.literal("alice"), RDF.literal("v1")],
            result: %Var{name: "Result"}
          }
        ]
      )

    rule2 =
      rule(
        %FactPattern{predicate: rel("greeted"), args: [RDF.literal("bob"), %Var{name: "Result"}]},
        [
          %FactPattern{
            predicate: rel("pendingDeploy"),
            args: [RDF.literal("bob"), RDF.literal("v2")]
          },
          %CapabilityReference{
            capability: cap("deployService"),
            args: [RDF.literal("bob"), RDF.literal("v2")],
            result: %Var{name: "Result"}
          }
        ]
      )

    assert {:ok, [{generalization, sub1, sub2}]} = AntiUnifier.generalize(rule1, rule2)

    assert all_generalization_vars?(generalization)

    # "alice"/"bob" recur in three places (head subject, pendingDeploy
    # subject, capability's first arg) — all three must share ONE
    # generalization variable, not three independent ones.
    subject_var = hd(generalization.head.args)
    [pending_deploy] = Enum.filter(generalization.body, &match?(%FactPattern{}, &1))
    [capability] = Enum.filter(generalization.body, &match?(%CapabilityReference{}, &1))
    assert hd(pending_deploy.args) == subject_var
    assert hd(capability.args) == subject_var

    # The two recovering substitutions must reconstruct each original Rule
    # exactly when applied to the generalization.
    assert substitute_rule(generalization, sub1) == rule1
    assert substitute_rule(generalization, sub2) == rule2
  end

  test "different Head predicates have no common structure" do
    rule1 = rule(%FactPattern{predicate: rel("a"), args: [%Var{name: "X"}, %Var{name: "Y"}]}, [])
    rule2 = rule(%FactPattern{predicate: rel("b"), args: [%Var{name: "X"}, %Var{name: "Y"}]}, [])

    assert AntiUnifier.generalize(rule1, rule2) == {:error, :no_common_structure}
  end

  test "a Body longer than 32 literals is rejected before any search begins" do
    body =
      for i <- 1..33 do
        %FactPattern{predicate: rel("f#{i}"), args: [%Var{name: "A#{i}"}, %Var{name: "B#{i}"}]}
      end

    big_rule =
      rule(%FactPattern{predicate: rel("out"), args: [%Var{name: "X"}, %Var{name: "Y"}]}, body)

    small_rule =
      rule(%FactPattern{predicate: rel("out"), args: [%Var{name: "X"}, %Var{name: "Y"}]}, [])

    assert AntiUnifier.generalize(big_rule, small_rule) == {:error, :body_too_large}
    assert AntiUnifier.generalize(small_rule, big_rule) == {:error, :body_too_large}
  end

  test "same-named-but-unrelated variables never shortcut into the generalization unchanged" do
    # Both rules use "X" for their head subject AND their bar/2 subject --
    # the SAME (Var{"X"}, Var{"X"}) pair recurs, so the correct behavior is
    # to reuse one fresh generalization variable across both occurrences.
    # A buggy implementation that treats same-named Vars as "already
    # equal" would instead leave the literal name "X" in the output.
    rule1 =
      rule(%FactPattern{predicate: rel("foo"), args: [%Var{name: "X"}, RDF.literal("a")]}, [
        %FactPattern{predicate: rel("bar"), args: [%Var{name: "X"}, RDF.literal("p")]}
      ])

    rule2 =
      rule(%FactPattern{predicate: rel("foo"), args: [%Var{name: "X"}, RDF.literal("b")]}, [
        %FactPattern{predicate: rel("bar"), args: [%Var{name: "X"}, RDF.literal("q")]}
      ])

    assert {:ok, [{generalization, _sub1, _sub2}]} = AntiUnifier.generalize(rule1, rule2)
    assert all_generalization_vars?(generalization)

    # The shared X-vs-X pair must generalize to ONE variable, reused in
    # both the head subject and bar's subject.
    [subject_var, _] = generalization.head.args
    [bar] = generalization.body
    assert hd(bar.args) == subject_var
  end

  test "two same-predicate Body literals admit multiple alignments, tied at the same minimum variable count" do
    rule1 =
      rule(%FactPattern{predicate: rel("pair"), args: [%Var{name: "X"}, %Var{name: "Y"}]}, [
        %FactPattern{predicate: rel("likes"), args: [%Var{name: "X"}, RDF.literal("cats")]},
        %FactPattern{predicate: rel("likes"), args: [%Var{name: "Y"}, RDF.literal("dogs")]}
      ])

    rule2 =
      rule(%FactPattern{predicate: rel("pair"), args: [%Var{name: "A"}, %Var{name: "B"}]}, [
        %FactPattern{predicate: rel("likes"), args: [%Var{name: "A"}, RDF.literal("dogs")]},
        %FactPattern{predicate: rel("likes"), args: [%Var{name: "B"}, RDF.literal("cats")]}
      ])

    assert {:ok, candidates} = AntiUnifier.generalize(rule1, rule2)

    # Both valid pairings (straight: X~A,Y~B; crossed: X~B,Y~A) introduce
    # exactly 4 distinct fresh variables each and are mutually incomparable
    # — neither should be discarded in favor of the other. The straight
    # pairing legitimately reuses two of those variables across the head
    # and body (per the shared-memo-map sharing rule), so occurrence count
    # differs between the two candidates even though distinct-variable
    # count does not — hence dedup before counting.
    assert length(candidates) == 2

    for {generalization, _sub1, _sub2} <- candidates do
      assert all_generalization_vars?(generalization)
      assert generalization |> vars_in_rule() |> Enum.uniq() |> length() == 4
    end

    # The two candidates must actually be structurally different from
    # each other (not two copies of the same generalization).
    [{gen1, _, _}, {gen2, _, _}] = candidates
    refute gen1.body == gen2.body
  end

  defp substitute_rule(%Rule{head: head, body: body, signature: signature} = rule, substitution) do
    %{
      rule
      | head: substitute_literal(head, substitution),
        body: Enum.map(body, &substitute_literal(&1, substitution)),
        signature: %{
          signature
          | parameters: Enum.map(signature.parameters, &substitute_term(&1, substitution))
        }
    }
  end

  defp substitute_literal(%FactPattern{} = lit, substitution) do
    %{lit | args: Enum.map(lit.args, &substitute_term(&1, substitution))}
  end

  defp substitute_literal(%CapabilityReference{} = lit, substitution) do
    %{
      lit
      | args: Enum.map(lit.args, &substitute_term(&1, substitution)),
        result: substitute_term(lit.result, substitution)
    }
  end

  defp substitute_term(%Var{} = var, substitution), do: Map.fetch!(substitution, var)
  defp substitute_term(term, _substitution), do: term
end
