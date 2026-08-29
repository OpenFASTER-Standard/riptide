defmodule Riptide.Derivation.LLMFallback.Client do
  @moduledoc """
  Pluggable LLM access point for `Riptide.Derivation.LLMFallback` —
  Riptide's own platform-level reasoning step, not a tenant-granted
  external-system Capability (design spec
  `docs/superpowers/specs/2026-08-29-phase-6f-llm-fallback-loop-design.md`
  §2). Configured via `Application.get_env(:riptide, :llm_fallback_client,
  ...)`, the same pattern `Riptide.Authz` already uses for `:authz_store`.
  """

  @callback complete(prompt :: String.t()) :: {:ok, String.t()} | {:error, term()}
end

defmodule Riptide.Derivation.LLMFallback do
  @moduledoc """
  Task with no Catalog match -> LLM-guided Capability invocation -> ground
  Trace. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6f-llm-fallback-loop-design.md`.
  """

  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.{AntiUnifier, ExecuteInterpreter, Parser, Rule}

  @spec run(String.t(), RDF.Graph.t(), Context.t()) ::
          {:ok, Rule.t()}
          | {:error,
             {:llm_error, term()}
             | {:unparseable_response, term()}
             | :no_match
             | :ambiguous_match
             | {:unresolvable, RDF.IRI.t()}
             | {:unsupported_arity, RDF.IRI.t()}}
  def run(task_description, %RDF.Graph{} = graph, %Context{} = context) do
    client =
      Application.get_env(:riptide, :llm_fallback_client, Riptide.Derivation.LLMFallback.Client.Anthropic)

    with {:ok, response_text} <- call_client(client, task_description, context),
         {:ok, candidate_rule} <- parse_response(response_text),
         {:ok, binding} <- resolve_exactly_one_binding(candidate_rule, graph, context) do
      {:ok, AntiUnifier.substitute(candidate_rule, binding)}
    end
  end

  defp call_client(client, task_description, context) do
    case client.complete(build_prompt(task_description, context)) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:llm_error, reason}}
    end
  end

  defp parse_response(text) do
    case Parser.decode(text) do
      {:ok, rule} -> {:ok, rule}
      {:error, reason} -> {:error, {:unparseable_response, reason}}
    end
  end

  defp resolve_exactly_one_binding(rule, graph, context) do
    with {:ok, bindings} <- ExecuteInterpreter.resolve_bindings(rule, graph, context) do
      case bindings do
        [] -> {:error, :no_match}
        [binding] -> {:ok, binding}
        [_ | _] -> {:error, :ambiguous_match}
      end
    end
  end

  defp build_prompt(task_description, context) do
    capability_names =
      context.capabilities |> Map.keys() |> Enum.map(&RDF.IRI.to_string/1) |> Enum.sort()

    rule_names = context.rules |> Map.keys() |> Enum.map(&RDF.IRI.to_string/1) |> Enum.sort()

    """
    You are generating a single Datalog-style rule clause for Riptide.

    Grammar:
      predicate(args) :- literal, literal, ..., literal.
    - Variables: UPPERCASE identifiers (e.g. Result, Target).
    - Opaque values: "quoted strings".
    - Entity references: <full IRI>.
    - Capability call: capability(name, arg, ..., result) - result is always the last argument.
    - Rule call: rule(name, arg, result).

    Available capabilities: #{Enum.join(capability_names, ", ")}
    Available rules: #{Enum.join(rule_names, ", ")}

    Task: #{task_description}

    Output ONLY the rule clause text. No markdown, no explanation, no other text.
    """
  end
end
