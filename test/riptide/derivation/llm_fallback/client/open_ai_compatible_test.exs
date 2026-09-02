defmodule Riptide.Derivation.LLMFallback.Client.OpenAICompatibleTest do
  use ExUnit.Case, async: false

  alias Riptide.Derivation.LLMFallback.Client.OpenAICompatible

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :llm_fallback_tesla_adapter, Tesla.Mock)
    System.put_env("LLM_API_BASE_URL", "https://example.test/v1")
    System.put_env("LLM_API_KEY", "test-key")
    System.put_env("LLM_API_MODEL", "test-model")

    on_exit(fn ->
      System.delete_env("LLM_API_BASE_URL")
      System.delete_env("LLM_API_KEY")
      System.delete_env("LLM_API_MODEL")
    end)

    :ok
  end

  test "complete/1 sends the prompt and extracts the response text" do
    Tesla.Mock.mock(fn %Tesla.Env{method: :post, url: url, body: body} = env ->
      assert url == "https://example.test/v1/chat/completions"
      assert {"authorization", "Bearer test-key"} in env.headers

      assert %{
               "model" => "test-model",
               "messages" => [%{"role" => "user", "content" => "greet Alice"}]
             } =
               Jason.decode!(body)

      %Tesla.Env{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{
            "choices" => [%{"message" => %{"content" => "greeted(...)."}}]
          })
      }
    end)

    assert OpenAICompatible.complete("greet Alice") == {:ok, "greeted(...)."}
  end

  test "a non-200 response surfaces as {:error, {:http_error, status, body}}" do
    Tesla.Mock.mock(fn _env -> %Tesla.Env{status: 429, body: "rate limited"} end)

    assert OpenAICompatible.complete("greet Alice") ==
             {:error, {:http_error, 429, "rate limited"}}
  end

  test "an unexpected response shape surfaces as {:error, {:unexpected_response_shape, body}}" do
    Tesla.Mock.mock(fn _env ->
      %Tesla.Env{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"unexpected" => "shape"})
      }
    end)

    assert OpenAICompatible.complete("greet Alice") ==
             {:error, {:unexpected_response_shape, %{"unexpected" => "shape"}}}
  end

  test "a missing LLM_API_BASE_URL surfaces as {:error, :missing_api_config}" do
    System.delete_env("LLM_API_BASE_URL")

    assert OpenAICompatible.complete("greet Alice") == {:error, :missing_api_config}
  end

  test "a missing LLM_API_KEY surfaces as {:error, :missing_api_config}" do
    System.delete_env("LLM_API_KEY")

    assert OpenAICompatible.complete("greet Alice") == {:error, :missing_api_config}
  end

  test "a missing LLM_API_MODEL surfaces as {:error, :missing_api_config}" do
    System.delete_env("LLM_API_MODEL")

    assert OpenAICompatible.complete("greet Alice") == {:error, :missing_api_config}
  end
end
