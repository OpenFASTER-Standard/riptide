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
    original = Application.get_env(:riptide, :auth_verifier)
    Application.put_env(:riptide, :auth_verifier, StubVerifier)
    on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original) end)
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

  test "falls back to a ?token= query param when no header is present" do
    conn =
      :get
      |> conn("/streams/abc/subscribe?token=valid-token")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == %{"sub" => "user-1"}
    refute conn.halted
  end

  test "prefers the header over the query param when both are present" do
    conn =
      :get
      |> conn("/streams/abc/subscribe?token=garbage")
      |> put_req_header("authorization", "Bearer valid-token")
      |> Authenticate.call(Authenticate.init([]))

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
