defmodule Riptide.Tenancy.Resolver.Subdomain do
  @moduledoc """
  Extracts tenant_id from `conn.host`'s leading subdomain label, e.g.
  `"acme.riptide.example"` -> `"acme"`. Requires at least 3 total labels (a
  tenant subdomain plus a base domain of at least 2 labels) so a bare base
  domain like `"riptide.example"` — with no tenant subdomain at all — isn't
  misread as tenant_id `"riptide"`. A single trailing dot (the root-zone
  marker of a fully-qualified domain name, e.g. `"riptide.example."`) is
  stripped before splitting so it isn't counted as an extra, empty label.
  """
  @behaviour Riptide.Tenancy.Resolver

  @impl true
  def resolve(%Plug.Conn{host: host}) do
    case host |> String.trim_trailing(".") |> String.split(".") do
      [tenant_id | rest] when tenant_id != "" and length(rest) >= 2 ->
        {:ok, tenant_id}

      _ ->
        {:error, :no_tenant_subdomain}
    end
  end
end
