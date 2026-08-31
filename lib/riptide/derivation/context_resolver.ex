defmodule Riptide.Derivation.ContextResolver do
  @moduledoc """
  Builds an `ExecuteInterpreter.Context` for a `jobRule` Job by transitively
  resolving its Rule body's Capability/Rule IRI references through 6k's
  `CapabilityCatalog` and the existing Rule `Catalog` — see design spec
  `docs/superpowers/specs/2026-08-31-phase-6l-reactive-job-triggering-design.md`
  §6. Not used for a `jobCapability` Job, which needs no `Context`/
  `ExecuteInterpreter` involvement at all.
  """

  alias Riptide.Derivation.CapabilityCatalog
  alias Riptide.Derivation.Catalog
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}

  @spec resolve(String.t(), map() | nil, RDF.IRI.t()) :: {:ok, Context.t()} | {:error, term()}
  def resolve(tenant_id, current_subject, rule_iri) do
    with {:ok, capabilities, rules} <- walk_rule(tenant_id, rule_iri, MapSet.new(), %{}, %{}) do
      {:ok,
       %Context{
         capabilities: capabilities,
         rules: rules,
         tenant_id: tenant_id,
         current_subject: current_subject
       }}
    end
  end

  defp walk_rule(tenant_id, iri, visited, capabilities, rules) do
    cond do
      # `rules` is added to on the way DOWN (before walking a Rule's own
      # body), not only once a subtree fully completes — so a node still
      # in progress on the CURRENT path is already present in `rules` too,
      # not just `visited`. Checking `visited` first is what actually
      # distinguishes "a genuine cycle back to an ancestor on this path"
      # from "already fully resolved via an earlier, unrelated branch" (a
      # diamond) — checking `rules` first would let a real cycle slip
      # through as a false "already resolved" (caught live: the very
      # first test run of the cycle-detection test returned {:ok, _}
      # instead of {:error, {:cycle_detected, _}}).
      MapSet.member?(visited, iri) ->
        {:error, {:cycle_detected, iri}}

      Map.has_key?(rules, iri) ->
        {:ok, capabilities, rules}

      true ->
        with {:ok, rule} <- find_rule(tenant_id, iri) do
          rules = Map.put(rules, iri, rule)
          visited = MapSet.put(visited, iri)
          walk_body(tenant_id, rule.body, visited, capabilities, rules)
        end
    end
  end

  defp walk_body(_tenant_id, [], _visited, capabilities, rules), do: {:ok, capabilities, rules}

  defp walk_body(tenant_id, [%FactPattern{} | rest], visited, capabilities, rules),
    do: walk_body(tenant_id, rest, visited, capabilities, rules)

  defp walk_body(
         tenant_id,
         [%CapabilityReference{capability: iri} | rest],
         visited,
         capabilities,
         rules
       ) do
    with {:ok, capabilities} <- resolve_capability(iri, capabilities) do
      walk_body(tenant_id, rest, visited, capabilities, rules)
    end
  end

  defp walk_body(tenant_id, [%RuleReference{rule: iri} | rest], visited, capabilities, rules) do
    with {:ok, capabilities, rules} <- walk_rule(tenant_id, iri, visited, capabilities, rules) do
      walk_body(tenant_id, rest, visited, capabilities, rules)
    end
  end

  defp resolve_capability(iri, capabilities) do
    if Map.has_key?(capabilities, iri) do
      {:ok, capabilities}
    else
      with {:ok, entry} <- capability_not_found(CapabilityCatalog.find_by_name(iri), iri),
           {:ok, definition} <- CapabilityCatalog.materialize(entry) do
        {:ok, Map.put(capabilities, iri, definition)}
      end
    end
  end

  defp capability_not_found({:ok, entry}, _iri), do: {:ok, entry}
  defp capability_not_found({:error, :not_found}, iri), do: {:error, {:not_found, iri}}

  # Tenant-scope first (a Job's own tenant may have installed/admitted a
  # private Rule under this IRI), falling back to Hub-scope (a globally
  # shared Rule the tenant hasn't installed but can still reference
  # directly) — mirrors every other Sub-project 6 catalog lookup's own
  # Tenant-before-Hub precedence.
  defp find_rule(tenant_id, iri) do
    case find_rule_in_scope({:tenant, tenant_id}, iri) do
      {:ok, rule} -> {:ok, rule}
      :not_found -> find_rule_in_scope(:hub, iri) |> rule_not_found(iri)
    end
  end

  defp find_rule_in_scope(scope, iri) do
    with {:ok, entries} <- Catalog.list_entries(scope) do
      find_by_signature_name(entries, iri)
    end
  end

  defp find_by_signature_name(entries, iri) do
    case Enum.find(entries, fn {_node, rule} -> rule.signature.name == iri end) do
      {_node, rule} -> {:ok, rule}
      nil -> :not_found
    end
  end

  defp rule_not_found(:not_found, iri), do: {:error, {:not_found, iri}}
  defp rule_not_found(result, _iri), do: result
end
