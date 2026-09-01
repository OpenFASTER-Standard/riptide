defmodule RiptideWeb.Plugs.Authenticate do
  @moduledoc """
  Extracts a bearer token (see `extract_token/1`) and verifies it via the
  configured `Riptide.Auth.Verifier`
  (`Application.get_env(:riptide, :auth_verifier)`, defaulting to
  `Riptide.Auth.Verifier.Composite` (tries OIDC, then Riptide's own password
  auth)) — mirrors `RiptideWeb.Plugs.ResolveTenant`'s config-driven swap
  (Phase 4a).

  Unlike `ResolveTenant`, authentication is optional at this layer: no token
  present assigns `conn.assigns.current_subject` to `nil` and lets the
  request proceed as anonymous. A token *is* present but fails verification
  halts with `401` — a token that can't be checked is never silently treated
  as though it had passed. Nothing yet enforces that `current_subject` be
  non-nil for any route; that's Phase 4c's job.

  The `?token=` query-param fallback (browsers' native `EventSource` API
  can't set custom request headers, so SSE has no other way to send a
  bearer token) is opt-in via `allow_query_param: true`, not a blanket
  behavior of this plug — see `RiptideWeb.Router`'s `:auth_query_param`
  pipeline, used only by the SSE subscribe route. A bearer token in a query
  string is a durable leak risk (proxy/access logs, browser history,
  `Referer` forwarding) that should never be enabled for routes that have a
  perfectly good `Authorization` header available, which is every route but
  SSE.
  """
  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case extract_token(conn, opts) do
      nil ->
        assign(conn, :current_subject, nil)

      token ->
        verifier = Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.Composite)

        case verifier.verify(token) do
          {:ok, claims} ->
            maybe_set_subject_metadata(claims)
            assign(conn, :current_subject, claims)

          {:error, reason} ->
            Logger.warning("auth verification failed", reason: inspect(reason))

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
  # §5). The query-param fallback only applies when the pipeline explicitly
  # opts in via `allow_query_param: true` — see moduledoc.
  defp extract_token(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> if Keyword.get(opts, :allow_query_param, false), do: fallback_token(conn)
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
