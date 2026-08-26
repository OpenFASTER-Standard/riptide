defmodule Riptide.Tenancy.Resolver do
  @moduledoc """
  Behaviour for extracting a tenant_id from an incoming request. Selected via
  `Application.get_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.PathSegment)`
  — the same config-driven swap `Riptide.RaCluster.default_ordinal_resolver/1`
  already uses (Phase 3c-i) for picking a resolution strategy per deployment.
  """

  @callback resolve(Plug.Conn.t()) :: {:ok, String.t()} | {:error, term()}
end
