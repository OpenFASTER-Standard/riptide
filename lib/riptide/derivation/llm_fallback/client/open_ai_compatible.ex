defmodule Riptide.Derivation.LLMFallback.Client.OpenAICompatible do
  @moduledoc """
  Real implementation of `Riptide.Derivation.LLMFallback.Client` against the OpenAI-compatible chat
  completions wire format — spoken natively or via a compatibility endpoint by nearly every LLM
  provider today, so this targets the format itself rather than any one vendor. Tesla-based (already a
  direct dependency, `mix.exs`), matching this project's existing outbound-HTTP precedent
  (`Riptide.Auth.JwksStrategy`'s JWKS fetch). See design spec
  `docs/superpowers/specs/2026-08-29-phase-6f-llm-fallback-loop-design.md` §4.
  """

  @behaviour Riptide.Derivation.LLMFallback.Client

  @impl true
  @spec complete(String.t()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt) do
    with {:ok, base_url, api_key, model} <- fetch_config(),
         {:ok, %Tesla.Env{status: 200, body: body}} <-
           Tesla.post(
             build_client(api_key),
             base_url <> "/chat/completions",
             request_body(model, prompt)
           ) do
      extract_text(body)
    else
      {:ok, %Tesla.Env{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_config do
    with base_url when is_binary(base_url) <- System.get_env("LLM_API_BASE_URL"),
         api_key when is_binary(api_key) <- System.get_env("LLM_API_KEY"),
         model when is_binary(model) <- System.get_env("LLM_API_MODEL") do
      {:ok, base_url, api_key, model}
    else
      nil -> {:error, :missing_api_config}
    end
  end

  defp build_client(api_key) do
    adapter = Application.get_env(:riptide, :llm_fallback_tesla_adapter, Tesla.Adapter.Httpc)

    Tesla.client(
      [
        {Tesla.Middleware.Headers, [{"authorization", "Bearer " <> api_key}]},
        Tesla.Middleware.JSON
      ],
      adapter
    )
  end

  defp request_body(model, prompt) do
    %{
      model: model,
      messages: [%{role: "user", content: prompt}]
    }
  end

  defp extract_text(%{"choices" => [%{"message" => %{"content" => text}} | _]}), do: {:ok, text}
  defp extract_text(body), do: {:error, {:unexpected_response_shape, body}}
end
