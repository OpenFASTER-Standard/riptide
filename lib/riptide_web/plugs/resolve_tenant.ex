defmodule RiptideWeb.Plugs.ResolveTenant do
  @moduledoc """
  Resolves `conn.assigns.tenant_id` via the configured
  `Riptide.Tenancy.Resolver` implementation
  (`Application.get_env(:riptide, :tenancy_resolver)`, defaulting to
  `Riptide.Tenancy.Resolver.PathSegment`) — mirrors
  `Riptide.RaCluster.default_ordinal_resolver/1`'s config-driven resolver
  swap (Phase 3c-i). Halts with `400` if no tenant_id can be resolved; no
  resource logic should ever run without a resolved tenant.

  A resolved `tenant_id` is additionally validated against a conservative
  safe charset (`[A-Za-z0-9._-]`) before being assigned. This is the single
  chokepoint both `PathSegment` and `Subdomain` flow through, so validating
  here closes a stream_id collision otherwise reachable via a `%2F`-encoded
  slash in a request path: Phoenix's router decodes each already-split path
  segment individually (see `deps/phoenix/lib/phoenix/router.ex`), so a raw
  `%2F` inside the `:tenant_id` segment becomes a literal `/` in the decoded
  value *before* `ResourceController.stream_id_for/2` concatenates it with
  `/resources/` and the resource path — letting a crafted tenant_id alias
  onto a different tenant's stream_id string. Rejecting any tenant_id that
  isn't purely `[A-Za-z0-9._-]` makes that concatenation collision-free,
  since none of the delimiter characters (`/`) can appear on either side of
  the join. An invalid tenant_id is treated exactly like an unresolvable
  one: halt with `400`.
  """
  import Plug.Conn

  @behaviour Plug

  @safe_tenant_id ~r/\A[A-Za-z0-9._-]+\z/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    resolver =
      Application.get_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.PathSegment)

    case resolver.resolve(conn) do
      {:ok, tenant_id} ->
        if Regex.match?(@safe_tenant_id, tenant_id) do
          assign(conn, :tenant_id, tenant_id)
        else
          reject(conn)
        end

      {:error, _reason} ->
        reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> send_resp(400, "")
    |> halt()
  end
end
