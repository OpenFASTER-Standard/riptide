defmodule RiptideWeb.Plugs.AuthenticateTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias RiptideWeb.Plugs.Authenticate

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("valid-token"), do: {:ok, %{"sub" => "user-1"}}
    def verify("no-sub-token"), do: {:ok, %{"other" => "claim"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    :ok
  end

  test "assigns current_subject to nil when no token is present" do
    conn =
      :get
      |> conn("/resources/foo")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == nil
    refute conn.halted
  end

  test "assigns current_subject from a valid Authorization: Bearer header" do
    conn =
      :get
      |> conn("/resources/foo")
      |> put_req_header("authorization", "Bearer valid-token")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == %{"sub" => "user-1"}
    refute conn.halted
  end

  test "halts with 401 when a header token fails verification" do
    conn =
      :get
      |> conn("/resources/foo")
      |> put_req_header("authorization", "Bearer garbage")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "falls back to a ?token= query param when no header is present and allow_query_param is set" do
    conn =
      :get
      |> conn("/streams/abc/subscribe?token=valid-token")
      |> Authenticate.call(Authenticate.init(allow_query_param: true))

    assert conn.assigns.current_subject == %{"sub" => "user-1"}
    refute conn.halted
  end

  test "ignores a ?token= query param when allow_query_param is not set (default)" do
    # A bearer token in a query string is a durable leak risk (proxy/access
    # logs, browser history, Referer forwarding) — the fallback only applies
    # when a pipeline explicitly opts in (see RiptideWeb.Router's
    # :auth_query_param pipeline, used only by the SSE subscribe route).
    conn =
      :get
      |> conn("/resources/foo?token=valid-token")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == nil
    refute conn.halted
  end

  test "prefers the header over the query param when both are present" do
    conn =
      :get
      |> conn("/streams/abc/subscribe?token=garbage")
      |> put_req_header("authorization", "Bearer valid-token")
      |> Authenticate.call(Authenticate.init(allow_query_param: true))

    assert conn.assigns.current_subject == %{"sub" => "user-1"}
    refute conn.halted
  end

  test "an unparseable Authorization header (no Bearer prefix) is treated as no token" do
    conn =
      :get
      |> conn("/resources/foo")
      |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == nil
    refute conn.halted
  end

  test "sets subject in Logger metadata when a valid token has a sub claim" do
    :get
    |> conn("/resources/foo")
    |> put_req_header("authorization", "Bearer valid-token")
    |> Authenticate.call(Authenticate.init([]))

    assert Logger.metadata()[:subject] == "user-1"
  end

  test "does not set subject in Logger metadata for an anonymous request" do
    :get
    |> conn("/resources/foo")
    |> Authenticate.call(Authenticate.init([]))

    refute Keyword.has_key?(Logger.metadata(), :subject)
  end

  test "does not set subject in Logger metadata when claims lack a sub" do
    :get
    |> conn("/resources/foo")
    |> put_req_header("authorization", "Bearer no-sub-token")
    |> Authenticate.call(Authenticate.init([]))

    refute Keyword.has_key?(Logger.metadata(), :subject)
  end
end
