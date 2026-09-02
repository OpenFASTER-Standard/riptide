defmodule RiptideWeb.Auth.TenantNamesController do
  @moduledoc """
  `GET /tenant-names/:name` — resolves a tenant's chosen name to its opaque `tenant_id`. Anonymous, like
  every other `/auth/*` route: resolving a public name is not itself sensitive (design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.2).
  """
  use Phoenix.Controller, formats: [:json]

  def show(conn, %{"name" => name}) do
    case Riptide.Placement.lookup_name(name) do
      nil ->
        send_resp(conn, 404, "")

      tenant_id ->
        body = Jason.encode!(%{"tenant_id" => tenant_id})
        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  rescue
    _ -> send_resp(conn, 503, "")
  catch
    :exit, _ -> send_resp(conn, 503, "")
  end
end
