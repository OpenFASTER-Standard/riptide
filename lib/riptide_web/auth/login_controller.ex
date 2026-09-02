defmodule RiptideWeb.Auth.LoginController do
  @moduledoc """
  `POST /auth/login` — deliberately anonymous (design spec
  `docs/superpowers/specs/2026-09-01-phase-6o-username-password-auth-design.md`
  §4.3). Not routed through `RiptideWeb.Plugs.Authenticate`/`Authorize` —
  there is no token yet to check; that's the entire point of this route.
  """

  use Phoenix.Controller, formats: [:json]

  def create(conn, params) do
    case conn |> caller_ip() |> Riptide.PasswordAuthRateLimit.check_login() do
      :deny -> send_resp(conn, 429, "")
      :allow -> handle_create(conn, params)
    end
  end

  defp handle_create(conn, %{
         "name" => name,
         "username" => username,
         "password_hash" => password_hash
       })
       when is_binary(name) and is_binary(username) and is_binary(password_hash) do
    case Riptide.Accounts.log_in(name, username, password_hash) do
      {:ok, token} ->
        body = Jason.encode!(%{"token" => token})
        conn |> put_resp_content_type("application/json") |> send_resp(200, body)

      {:error, :invalid_credentials} ->
        send_resp(conn, 401, "")

      {:error, :not_ready} ->
        send_resp(conn, 503, "")
    end
  rescue
    _ -> send_resp(conn, 503, "")
  catch
    :exit, _ -> send_resp(conn, 503, "")
  end

  defp handle_create(conn, _params), do: send_resp(conn, 400, "")

  # Same reasoning as SignupController's own caller_ip/1 — this route never
  # goes through the :auth pipeline, so it's always IP, never a subject.
  defp caller_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
