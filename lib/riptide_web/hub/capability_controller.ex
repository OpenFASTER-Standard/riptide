defmodule RiptideWeb.Hub.CapabilityController do
  @moduledoc """
  Propose a Capability (metadata + base64 bytes in one request) and
  approve/decline it, mirroring `RiptideWeb.Hub.CrosswalkController`'s exact
  shape (design spec
  `docs/superpowers/specs/2026-08-31-phase-6k-dynamic-capability-registration-design.md`
  §7).
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
         }
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

      case DedupGate.propose_capability({:tenant, tenant_id}, entry) do
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

  # Explicit case matching, not String.to_existing_atom/1 — mirrors
  # CrosswalkController's own parse_match_type/1 reasoning exactly.
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

  def approve(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id

    case DedupGate.approve_capability_review({:tenant, tenant_id}, RDF.BlankNode.new(node_id)) do
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
