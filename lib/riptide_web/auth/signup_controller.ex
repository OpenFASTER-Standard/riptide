defmodule RiptideWeb.Auth.SignupController do
  @moduledoc """
  `POST /auth/signup` — deliberately anonymous (design spec
  `docs/superpowers/specs/2026-09-01-phase-6o-username-password-auth-design.md`
  §4.2): creates a brand-new Tenant and its first account together. Not
  routed through `RiptideWeb.Plugs.Authenticate`/`Authorize` — there is no
  token yet to check.
  """

  use Phoenix.Controller, formats: [:json]
  require Logger

  @password_hash_pattern ~r/^[0-9a-f]{64}$/

  def create(conn, params) do
    case conn |> caller_ip() |> Riptide.PasswordAuthRateLimit.check_signup() do
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
    if valid_identifier?(name) and valid_identifier?(username) and
         Regex.match?(@password_hash_pattern, password_hash) do
      case Riptide.Accounts.sign_up(name, username, password_hash) do
        {:ok, %{token: token, sub: sub, tenant_id: tenant_id}} ->
          body = Jason.encode!(%{"token" => token, "sub" => sub, "tenant_id" => tenant_id})
          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        {:error, :already_claimed} ->
          send_resp(conn, 409, "")

        {:error, :not_ready} ->
          send_resp(conn, 503, "")
      end
    else
      send_resp(conn, 400, "")
    end
  rescue
    _ -> send_resp(conn, 503, "")
  catch
    :exit, _ -> send_resp(conn, 503, "")
  end

  defp handle_create(conn, _params), do: send_resp(conn, 400, "")

  # `username` becomes a stream_id path segment
  # (`RiptideWeb.LDP.ResourceController.stream_id_for/2`, which joins on
  # "/") — a "/" would corrupt addressing, so both `name` and `username`
  # are rejected here before any claim/write is attempted.
  defp valid_identifier?(value), do: value != "" and not String.contains?(value, "/")

  # Unlike Hub.DiscoveryController's own rate_limit_key/1 (which this
  # otherwise mirrors), this route never goes through the :auth pipeline at
  # all — conn.assigns[:current_subject] can never be set here, so there is
  # no subject-vs-IP branch to make; it's always IP.
  defp caller_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
