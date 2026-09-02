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

  @doc """
  Builds a Context populated with every Capability and every Rule admitted into `tenant_id`'s own
  Catalog (design spec `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md`
  §4.5 — each tenant's Catalog is now fully sovereign, no implicit Hub-scope merge) — unlike
  `resolve/3`, which transitively walks from one known starting Rule, this enumerates everything
  available up front, for a caller (Task submission, 6m) that doesn't yet know what it needs
  resolved. A Capability that fails to materialize (e.g. its blob is unreachable) is skipped, not
  fatal — LLMFallback simply won't be told about it, the same degraded-but-available behavior as if
  it had never been registered, rather than failing every Task submission because one unrelated
  Capability is temporarily broken.
  """
  @spec resolve_all(String.t(), map() | nil) :: {:ok, Context.t()}
  def resolve_all(tenant_id, current_subject) do
    {:ok,
     %Context{
       capabilities: all_capabilities(tenant_id),
       rules: all_rules(tenant_id),
       tenant_id: tenant_id,
       current_subject: current_subject
     }}
  end

  defp all_capabilities(tenant_id) do
    case Catalog.list_capabilities({:tenant, tenant_id}) do
      {:ok, entries} -> Enum.reduce(entries, %{}, &materialize_into/2)
      {:error, :not_ready} -> %{}
    end
  end

  defp materialize_into({_node, entry}, acc) do
    case CapabilityCatalog.materialize(entry) do
      {:ok, definition} -> Map.put(acc, entry.name, definition)
      {:error, _reason} -> acc
    end
  end

  defp all_rules(tenant_id), do: rules_by_signature_name({:tenant, tenant_id})

  defp rules_by_signature_name(scope) do
    case Catalog.list_entries(scope) do
      {:ok, entries} ->
        Map.new(entries, fn {_node, rule} -> {rule.signature.name, rule} end)

      {:error, :not_ready} ->
        %{}
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
    with {:ok, capabilities} <- resolve_capability(tenant_id, iri, capabilities) do
      walk_body(tenant_id, rest, visited, capabilities, rules)
    end
  end

  defp walk_body(tenant_id, [%RuleReference{rule: iri} | rest], visited, capabilities, rules) do
    with {:ok, capabilities, rules} <- walk_rule(tenant_id, iri, visited, capabilities, rules) do
      walk_body(tenant_id, rest, visited, capabilities, rules)
    end
  end

  defp resolve_capability(tenant_id, iri, capabilities) do
    if Map.has_key?(capabilities, iri) do
      {:ok, capabilities}
    else
      with {:ok, entry} <-
             capability_not_found(CapabilityCatalog.find_by_name({:tenant, tenant_id}, iri), iri),
           {:ok, definition} <- CapabilityCatalog.materialize(entry) do
        {:ok, Map.put(capabilities, iri, definition)}
      end
    end
  end

  defp capability_not_found({:ok, entry}, _iri), do: {:ok, entry}
  defp capability_not_found({:error, :not_found}, iri), do: {:error, {:not_found, iri}}

  defp find_rule(tenant_id, iri) do
    find_rule_in_scope({:tenant, tenant_id}, iri) |> rule_not_found(iri)
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
