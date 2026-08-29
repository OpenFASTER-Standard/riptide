defmodule Riptide.Derivation.LLMFallback.Client.AnthropicTest do
  use ExUnit.Case, async: false

  alias Riptide.Derivation.LLMFallback.Client.Anthropic

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :llm_fallback_tesla_adapter, Tesla.Mock)
    System.put_env("ANTHROPIC_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)
    :ok
  end

  test "complete/1 sends the prompt and extracts the response text" do
    Tesla.Mock.mock(fn %Tesla.Env{method: :post, url: url, body: body} = env ->
      assert url == "https://api.anthropic.com/v1/messages"
      assert {"x-api-key", "test-key"} in env.headers
      assert {"anthropic-version", "2023-06-01"} in env.headers

      assert %{"messages" => [%{"role" => "user", "content" => "greet Alice"}]} =
               Jason.decode!(body)

      # Tesla.Middleware.JSON only auto-decodes a response when the response
      # itself carries a `content-type: application/json` header (verified
      # directly — without it, `Anthropic.complete/1`'s own `body` argument
      # stays a raw JSON string and `extract_text/1` would fail to match).
      # A real Anthropic API response always sets this, so this is also more
      # realistic mock data, not just a workaround.
      %Tesla.Env{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"content" => [%{"type" => "text", "text" => "greeted(...)."}]})
      }
    end)

    assert Anthropic.complete("greet Alice") == {:ok, "greeted(...)."}
  end

  test "a non-200 response surfaces as {:error, {:http_error, status, body}}" do
    Tesla.Mock.mock(fn _env -> %Tesla.Env{status: 429, body: "rate limited"} end)

    assert Anthropic.complete("greet Alice") == {:error, {:http_error, 429, "rate limited"}}
  end

  test "a missing ANTHROPIC_API_KEY surfaces as {:error, :missing_api_key}" do
    System.delete_env("ANTHROPIC_API_KEY")

    assert Anthropic.complete("greet Alice") == {:error, :missing_api_key}
  end
end
