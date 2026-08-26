defmodule RiptideWeb.Plugs.ResolveTenant do
  @moduledoc """
  Resolves `conn.assigns.tenant_id` via the configured
  `Riptide.Tenancy.Resolver` implementation
  (`Application.get_env(:riptide, :tenancy_resolver)`, defaulting to
  `Riptide.Tenancy.Resolver.PathSegment`) — mirrors
  `Riptide.RaCluster.default_ordinal_resolver/1`'s config-driven resolver
  swap (Phase 3c-i). Halts with `400` if no tenant_id can be resolved; no
  resource logic should ever run without a resolved tenant.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    resolver =
      Application.get_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.PathSegment)

    case resolver.resolve(conn) do
      {:ok, tenant_id} ->
        assign(conn, :tenant_id, tenant_id)

      {:error, _reason} ->
        conn
        |> send_resp(400, "")
        |> halt()
    end
  end
end
