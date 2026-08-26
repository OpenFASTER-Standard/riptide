defmodule Riptide.Tenancy.Resolver.Subdomain do
  @moduledoc """
  Extracts tenant_id from `conn.host`'s leading subdomain label, e.g.
  `"acme.riptide.example"` -> `"acme"`. Requires at least 3 total labels (a
  tenant subdomain plus a base domain of at least 2 labels) so a bare base
  domain like `"riptide.example"` — with no tenant subdomain at all — isn't
  misread as tenant_id `"riptide"`.
  """
  @behaviour Riptide.Tenancy.Resolver

  @impl true
  def resolve(%Plug.Conn{host: host}) do
    case String.split(host, ".") do
      [tenant_id | rest] when tenant_id != "" and length(rest) >= 2 ->
        {:ok, tenant_id}

      _ ->
        {:error, :no_tenant_subdomain}
    end
  end
end
