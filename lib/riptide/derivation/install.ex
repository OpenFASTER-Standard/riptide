defmodule Riptide.Derivation.Install do
  @moduledoc """
  Installing a Hub Pattern into a Tenant with partial vocabulary overlap
  (design spec
  `docs/superpowers/specs/2026-08-30-phase-6i-crosswalks-and-installation-design.md`
  §7, §8).
  """

  alias Riptide.Derivation.{Catalog, Provenance, Rule}
  alias Riptide.Derivation.Literal.FactPattern

  @doc """
  A Tenant's vocabulary is observed, not declared (design spec §7,
  parent spec §3.1) — the union of every predicate IRI already appearing
  in `reads`/`produces` across that Tenant's own admitted Catalog
  entries.
  """
  @spec tenant_vocabulary(String.t()) :: MapSet.t(RDF.IRI.t())
  def tenant_vocabulary(tenant_id) do
    {:ok, entries} = Catalog.list_entries({:tenant, tenant_id})

    entries
    |> Enum.flat_map(fn {_node, rule} -> rule.signature.reads ++ rule.signature.produces end)
    |> MapSet.new()
  end

  @doc """
  Rewrites `pattern`'s predicates through existing Crosswalks into
  `tenant_id`'s own vocabulary where possible, leaving anything
  unmatched in the pattern's own native form, and stamps `:installed_from`
  Provenance recording exactly which fields were bound how (design spec
  §8).
  """
  @spec install(RDF.BlankNode.t(), Rule.t(), String.t()) ::
          {Rule.t(), [Provenance.field_binding()]}
  def install(hub_entry_node, %Rule{} = pattern, tenant_id) do
    vocabulary = tenant_vocabulary(tenant_id)
    {:ok, crosswalks} = Catalog.list_crosswalks({:tenant, tenant_id})
    predicates = pattern.signature.reads ++ pattern.signature.produces

    {rewrites, field_bindings} =
      Enum.reduce(predicates, {%{}, []}, fn predicate, {rewrites, bindings} ->
        cond do
          MapSet.member?(vocabulary, predicate) ->
            {rewrites, bindings}

          match = find_crosswalk(crosswalks, predicate, vocabulary) ->
            {crosswalk_node, target_predicate} = match

            {Map.put(rewrites, predicate, target_predicate),
             [%{predicate: predicate, binding: {:crosswalk, crosswalk_node}} | bindings]}

          true ->
            {rewrites, [%{predicate: predicate, binding: :manual} | bindings]}
        end
      end)

    field_bindings = Enum.reverse(field_bindings)

    installed_rule = %{
      rewrite_predicates(pattern, rewrites)
      | provenance: %Provenance{origin: {:installed_from, hub_entry_node, field_bindings}}
    }

    {installed_rule, field_bindings}
  end

  defp find_crosswalk(crosswalks, predicate, vocabulary) do
    Enum.find_value(crosswalks, fn {node, crosswalk} ->
      cond do
        crosswalk.subject_predicate == predicate and
            MapSet.member?(vocabulary, crosswalk.object_predicate) ->
          {node, crosswalk.object_predicate}

        crosswalk.object_predicate == predicate and
            MapSet.member?(vocabulary, crosswalk.subject_predicate) ->
          {node, crosswalk.subject_predicate}

        true ->
          nil
      end
    end)
  end

  defp rewrite_predicates(%Rule{} = rule, rewrites) when map_size(rewrites) == 0, do: rule

  defp rewrite_predicates(%Rule{} = rule, rewrites) do
    %{
      rule
      | head: rewrite_literal(rule.head, rewrites),
        body: Enum.map(rule.body, &rewrite_literal(&1, rewrites))
    }
  end

  defp rewrite_literal(%FactPattern{predicate: predicate} = literal, rewrites) do
    %{literal | predicate: Map.get(rewrites, predicate, predicate)}
  end

  defp rewrite_literal(literal, _rewrites), do: literal
end
