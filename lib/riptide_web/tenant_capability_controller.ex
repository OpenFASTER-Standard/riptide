defmodule RiptideWeb.TenantCapabilityController do
  @moduledoc """
  Propose a Capability into the caller's own tenant Catalog, and approve/decline it — a direct
  Tenant-scoped analogue of the deleted `RiptideWeb.Hub.CapabilityController` (design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.5). "Publishing" is no
  longer a distinct action here — admit into your own Catalog, then separately grant it a `:public`
  read policy via `POST /tenants/:tenant_id/policies`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.BlobStore
  alias Riptide.Derivation.{CapabilityCatalogEntry, DedupGate}

  def propose(conn, params) do
    tenant_id = conn.assigns.tenant_id

    case Riptide.HubRateLimit.check_propose(tenant_id) do
      :deny -> send_resp(conn, 429, "")
      :allow -> handle_propose(conn, tenant_id, params)
    end
  end

  defp handle_propose(
         conn,
         tenant_id,
         %{
           "name" => name,
           "kind" => kind_string,
           "function" => function,
           "fuel_limit" => fuel_limit,
           "timeout_ms" => timeout_ms,
           "memory_limits" => memory_limits_params,
           "component_bytes" => component_bytes_b64
         } = params
       ) do
    with {:ok, kind} <- parse_kind(kind_string),
         {:ok, bytes} <- Base.decode64(component_bytes_b64),
         {:ok, hash} <- BlobStore.put(bytes) do
      entry = %CapabilityCatalogEntry{
        name: RDF.iri(name),
        kind: kind,
        component_hash: hash,
        function: function,
        fuel_limit: fuel_limit,
        timeout_ms: timeout_ms,
        memory_limits: parse_memory_limits(memory_limits_params)
      }

      scope = {:tenant, tenant_id}
      replaces = parse_replaces(params)

      case DedupGate.propose_capability(scope, scope, entry, replaces) do
        {:ok, node} ->
          body = Jason.encode!(%{"outcome" => "queued", "node_id" => RDF.BlankNode.value(node)})
          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        {:error, _reason} ->
          send_resp(conn, 503, "")
      end
    else
      _error -> send_resp(conn, 400, "")
    end
  end

  defp handle_propose(conn, _tenant_id, _params), do: send_resp(conn, 400, "")

  defp parse_kind("effect"), do: {:ok, :effect}
  defp parse_kind("observe"), do: {:ok, :observe}
  defp parse_kind(_other), do: {:error, :invalid_kind}

  defp parse_memory_limits(params) do
    %{
      max_memory_size: Map.get(params, "max_memory_size"),
      max_table_elements: Map.get(params, "max_table_elements"),
      max_instances: Map.get(params, "max_instances"),
      max_tables: Map.get(params, "max_tables")
    }
  end

  defp parse_replaces(%{"replaces" => node_id}) when is_binary(node_id),
    do: RDF.BlankNode.new(node_id)

  defp parse_replaces(_params), do: nil

  def approve(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id
    scope = {:tenant, tenant_id}

    case DedupGate.approve_capability_review(scope, scope, RDF.BlankNode.new(node_id)) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, _reason} -> send_resp(conn, 503, "")
    end
  end

  def decline(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id

    case DedupGate.decline_capability_review({:tenant, tenant_id}, RDF.BlankNode.new(node_id)) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, _reason} -> send_resp(conn, 503, "")
    end
  end
end
