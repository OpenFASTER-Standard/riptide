defmodule RiptideWeb.Plugs.Authenticate do
  @moduledoc """
  Extracts a bearer token (see `extract_token/1`) and verifies it via the
  configured `Riptide.Auth.Verifier`
  (`Application.get_env(:riptide, :auth_verifier)`, defaulting to
  `Riptide.Auth.Verifier.OIDC`) — mirrors `RiptideWeb.Plugs.ResolveTenant`'s
  config-driven swap (Phase 4a).

  Unlike `ResolveTenant`, authentication is optional at this layer: no token
  present assigns `conn.assigns.current_subject` to `nil` and lets the
  request proceed as anonymous. A token *is* present but fails verification
  halts with `401` — a token that can't be checked is never silently treated
  as though it had passed. Nothing yet enforces that `current_subject` be
  non-nil for any route; that's Phase 4c's job.
  """
  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case extract_token(conn) do
      nil ->
        assign(conn, :current_subject, nil)

      token ->
        verifier = Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)

        case verifier.verify(token) do
          {:ok, claims} ->
            maybe_set_subject_metadata(claims)
            assign(conn, :current_subject, claims)

          {:error, _reason} ->
            conn
            |> send_resp(401, "")
            |> halt()
        end
    end
  end

  # subject stays genuinely absent from metadata (not present-but-nil) when
  # claims lack a `sub` — Phase 4b's TokenConfig doesn't require one.
  defp maybe_set_subject_metadata(claims) do
    if sub = claims["sub"], do: Logger.metadata(subject: sub)
  end

  # Header takes precedence over the query param when both are present, to
  # avoid ambiguity about which one is authoritative (Phase 4b design spec
  # §5). The query-param fallback exists only for SSE — browsers' native
  # `EventSource` API can't set custom request headers — but is accepted
  # here unconditionally rather than gated per-route: an LDP HTTP request
  # simply never sends a `?token=` param today, so this costs nothing there.
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> fallback_token(conn)
    end
  end

  # `query_params` is `%Plug.Conn.Unfetched{}` until explicitly fetched —
  # the router's own `:accepts` plug never fetches it, so it must be fetched
  # here rather than read directly off `conn.query_params`.
  defp fallback_token(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Map.fetch!(:query_params)
    |> Map.get("token")
  end
end
