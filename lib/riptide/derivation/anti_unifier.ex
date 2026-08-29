defmodule Riptide.Derivation.AntiUnifier do
  @moduledoc """
  Rule × Rule → Rule least-general-generalization (Plotkin 1970), with
  bottom-clause-style bounding arbitrating multiple mutually-incomparable
  candidates. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6e-i-anti-unification-design.md`.

  A Var never short-circuits the "already the same" fast path — not even
  when both sides share a string name — since variable names are
  rule-local and arbitrary (§3 of the design spec). Every Var comparison
  goes through the shared, injective memo map below.
  """

  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}
  alias Riptide.Derivation.{Rule, Signature, Var}

  @max_body_length 32

  @type substitution :: %{Var.t() => RDF.Term.t() | Var.t()}

  @spec generalize(Rule.t(), Rule.t()) ::
          {:ok, [{Rule.t(), substitution, substitution}]}
          | {:error, :no_common_structure | :body_too_large}
  def generalize(%Rule{} = rule1, %Rule{} = rule2) do
    with :ok <- check_body_length(rule1),
         :ok <- check_body_length(rule2),
         :ok <- check_heads_compatible(rule1.head, rule2.head) do
      existing_var_names = collect_var_names(rule1, rule2)

      candidates =
        rule1.body
        |> alignments(rule2.body)
        |> Enum.map(&build_candidate(rule1.head, rule2.head, &1, existing_var_names))

      {:ok, narrow_by_variable_count(candidates)}
    end
  end

  defp check_body_length(%Rule{body: body}) do
    if length(body) > @max_body_length, do: {:error, :body_too_large}, else: :ok
  end

  defp check_heads_compatible(%FactPattern{predicate: p}, %FactPattern{predicate: p}), do: :ok
  defp check_heads_compatible(_head1, _head2), do: {:error, :no_common_structure}

  # Alignments are built and returned in body1's own literal order, so the
  # generalized Body's literal order (and thus its substitution round-trip)
  # matches body1's — grouping/enumerating by key alone loses that order.
  defp alignments(body1, body2) do
    indexed_body1 = Enum.with_index(body1)
    groups1 = Enum.group_by(indexed_body1, fn {lit, _idx} -> literal_key(lit) end)
    groups2 = Enum.group_by(body2, &literal_key/1)
    shared_keys = MapSet.intersection(MapSet.new(Map.keys(groups1)), MapSet.new(Map.keys(groups2)))

    shared_keys
    |> Enum.map(fn key -> all_bijections(Map.fetch!(groups1, key), Map.fetch!(groups2, key)) end)
    |> cartesian_product()
    |> Enum.map(fn combo ->
      combo
      |> List.flatten()
      |> Enum.sort_by(fn {{_lit1, idx}, _lit2} -> idx end)
      |> Enum.map(fn {{lit1, _idx}, lit2} -> {lit1, lit2} end)
    end)
  end

  # All ways to pair up to min(length(list_a), length(list_b)) elements
  # between the two lists — the shorter list is always fully paired; the
  # longer list's excess elements are left unmatched in that pairing (and
  # WHICH excess elements are left out, and in what order the rest pair,
  # both vary across the returned alignments).
  defp all_bijections(list_a, list_b) when length(list_a) <= length(list_b) do
    list_b
    |> combinations(length(list_a))
    |> Enum.flat_map(&permutations/1)
    |> Enum.map(fn chosen_b -> Enum.zip(list_a, chosen_b) end)
  end

  defp all_bijections(list_a, list_b) do
    list_b
    |> all_bijections(list_a)
    |> Enum.map(fn pairs -> Enum.map(pairs, fn {b, a} -> {a, b} end) end)
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for elem <- list, rest <- permutations(list -- [elem]), do: [elem | rest]
  end

  defp combinations(_list, 0), do: [[]]
  defp combinations([], _n), do: []

  defp combinations([head | tail], n) do
    with_head = for combo <- combinations(tail, n - 1), do: [head | combo]
    without_head = combinations(tail, n)
    with_head ++ without_head
  end

  defp cartesian_product([]), do: [[]]

  defp cartesian_product([options | rest]) do
    for option <- options, combo <- cartesian_product(rest), do: [option | combo]
  end

  defp literal_key(%FactPattern{predicate: p, args: args}), do: {:fact_pattern, p, length(args)}

  defp literal_key(%CapabilityReference{capability: c, args: args}),
    do: {:capability_reference, c, length(args)}

  defp literal_key(%RuleReference{rule: r, args: args}), do: {:rule_reference, r, length(args)}

  defp collect_var_names(rule1, rule2) do
    [rule1, rule2]
    |> Enum.flat_map(&vars_in_rule/1)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp vars_in_rule(%Rule{head: head, body: body}) do
    Enum.flat_map([head | body], &vars_in_literal/1)
  end

  defp vars_in_literal(%FactPattern{args: args}), do: Enum.filter(args, &match?(%Var{}, &1))

  defp vars_in_literal(%CapabilityReference{args: args, result: result}) do
    Enum.filter([result | args], &match?(%Var{}, &1))
  end

  defp vars_in_literal(%RuleReference{args: args, result: result}) do
    Enum.filter([result | args], &match?(%Var{}, &1))
  end

  defp build_candidate(head1, head2, pairs, existing_var_names) do
    state0 = %{memo: %{}, counter: 0, existing: existing_var_names}

    {subject, state1} = anti_unify_term(Enum.at(head1.args, 0), Enum.at(head2.args, 0), state0)
    {object, state2} = anti_unify_term(Enum.at(head1.args, 1), Enum.at(head2.args, 1), state1)
    generalized_head = %FactPattern{predicate: head1.predicate, args: [subject, object]}

    {body, final_state} =
      Enum.map_reduce(pairs, state2, fn {lit1, lit2}, state ->
        anti_unify_literal_pair(lit1, lit2, state)
      end)

    signature = derive_signature(generalized_head, body)
    generalized_rule = %Rule{signature: signature, head: generalized_head, body: body}
    {sub1, sub2} = build_substitutions(final_state.memo)

    {generalized_rule, map_size(final_state.memo), sub1, sub2}
  end

  defp anti_unify_literal_pair(
         %FactPattern{predicate: p, args: [s1, o1]},
         %FactPattern{args: [s2, o2]},
         state
       ) do
    {subject, state1} = anti_unify_term(s1, s2, state)
    {object, state2} = anti_unify_term(o1, o2, state1)
    {%FactPattern{predicate: p, args: [subject, object]}, state2}
  end

  defp anti_unify_literal_pair(
         %CapabilityReference{capability: c, args: args1, result: result1},
         %CapabilityReference{args: args2, result: result2},
         state
       ) do
    {generalized_args, state1} =
      Enum.map_reduce(Enum.zip(args1, args2), state, fn {a1, a2}, s -> anti_unify_term(a1, a2, s) end)

    {generalized_result, state2} = anti_unify_term(result1, result2, state1)
    {%CapabilityReference{capability: c, args: generalized_args, result: generalized_result}, state2}
  end

  defp anti_unify_literal_pair(
         %RuleReference{rule: r, args: args1, result: result1},
         %RuleReference{args: args2, result: result2},
         state
       ) do
    {generalized_args, state1} =
      Enum.map_reduce(Enum.zip(args1, args2), state, fn {a1, a2}, s -> anti_unify_term(a1, a2, s) end)

    {generalized_result, state2} = anti_unify_term(result1, result2, state1)
    {%RuleReference{rule: r, args: generalized_args, result: generalized_result}, state2}
  end

  defp anti_unify_term(t1, t2, state) do
    if same_shape?(t1, t2) do
      {t1, state}
    else
      case Map.fetch(state.memo, {t1, t2}) do
        {:ok, var} ->
          {var, state}

        :error ->
          {var, counter} = fresh_var(state.counter, state.existing)
          {var, %{state | memo: Map.put(state.memo, {t1, t2}, var), counter: counter}}
      end
    end
  end

  # A Var never takes the "already the same" fast path — see moduledoc.
  defp same_shape?(%Var{}, _t2), do: false
  defp same_shape?(_t1, %Var{}), do: false
  defp same_shape?(t1, t2), do: t1 == t2

  defp fresh_var(counter, existing_var_names) do
    name = "$au_#{counter}"

    if MapSet.member?(existing_var_names, name) do
      fresh_var(counter + 1, existing_var_names)
    else
      {%Var{name: name}, counter + 1}
    end
  end

  defp derive_signature(%FactPattern{predicate: name, args: params}, body) do
    reads =
      body
      |> Enum.filter(&match?(%FactPattern{}, &1))
      |> Enum.map(& &1.predicate)
      |> Enum.uniq()

    %Signature{name: name, parameters: params, reads: reads, produces: [name]}
  end

  defp build_substitutions(memo) do
    sub1 = Map.new(memo, fn {{s, _t}, var} -> {var, s} end)
    sub2 = Map.new(memo, fn {{_s, t}, var} -> {var, t} end)
    {sub1, sub2}
  end

  defp narrow_by_variable_count(candidates) do
    min_count = candidates |> Enum.map(fn {_rule, count, _sub1, _sub2} -> count end) |> Enum.min()

    candidates
    |> Enum.filter(fn {_rule, count, _sub1, _sub2} -> count == min_count end)
    |> Enum.map(fn {rule, _count, sub1, sub2} -> {rule, sub1, sub2} end)
  end
end
