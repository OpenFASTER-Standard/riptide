defmodule Riptide.Derivation.LLMFallback.Client.Anthropic do
  @moduledoc """
  Real implementation of `Riptide.Derivation.LLMFallback.Client` against
  Anthropic's Messages API. Tesla-based (already a direct dependency,
  `mix.exs`), matching this project's existing outbound-HTTP precedent
  (`Riptide.Auth.JwksStrategy`'s JWKS fetch). See design spec
  `docs/superpowers/specs/2026-08-29-phase-6f-llm-fallback-loop-design.md`
  §4.
  """

  @behaviour Riptide.Derivation.LLMFallback.Client

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @model "claude-sonnet-5"
  @max_tokens 1024

  @impl true
  @spec complete(String.t()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, %Tesla.Env{status: 200, body: body}} <-
           Tesla.post(build_client(api_key), @api_url, request_body(prompt)) do
      extract_text(body)
    else
      {:ok, %Tesla.Env{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  defp build_client(api_key) do
    adapter = Application.get_env(:riptide, :llm_fallback_tesla_adapter, Tesla.Adapter.Httpc)

    Tesla.client(
      [
        {Tesla.Middleware.Headers, [{"x-api-key", api_key}, {"anthropic-version", @api_version}]},
        Tesla.Middleware.JSON
      ],
      adapter
    )
  end

  defp request_body(prompt) do
    %{
      model: @model,
      max_tokens: @max_tokens,
      messages: [%{role: "user", content: prompt}]
    }
  end

  defp extract_text(%{"content" => [%{"type" => "text", "text" => text} | _]}), do: {:ok, text}
  defp extract_text(body), do: {:error, {:unexpected_response_shape, body}}
end
