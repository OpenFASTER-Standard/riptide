defmodule Riptide.Tenancy.Resolver.PathSegment do
  @moduledoc """
  Extracts tenant_id from a `:tenant_id` path parameter — i.e. a router scope
  shaped `/tenants/:tenant_id/...`. Reads `conn.params["tenant_id"]` rather
  than parsing `conn.path_info` directly: Phoenix binds a matched route's path
  params before running that route's `pipe_through` pipeline, so by the time
  any plug in the pipeline runs, `conn.params` already has `tenant_id` set for
  any route under such a scope.
  """
  @behaviour Riptide.Tenancy.Resolver

  @impl true
  def resolve(%Plug.Conn{params: %{"tenant_id" => tenant_id}}) when tenant_id != "" do
    {:ok, tenant_id}
  end

  def resolve(%Plug.Conn{}) do
    {:error, :no_tenant_segment}
  end
end
