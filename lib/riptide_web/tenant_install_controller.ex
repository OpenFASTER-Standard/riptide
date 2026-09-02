defmodule RiptideWeb.TenantInstallController do
  @moduledoc """
  Install another tenant's admitted Catalog entry into the caller's own Catalog, applying Crosswalk
  auto-mapping (design spec `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md`
  §4.5). The caller must already know which tenant to install from (`source_tenant_id`) — general
  discovery of *unknown* tenants is explicitly out of scope (spec §3). Direct Tenant-scoped successor
  to the deleted `RiptideWeb.Hub.InstallController`; `target_scope`/`review_scope` are always the
  installing tenant's own `{:tenant, tenant_id}`, exactly as that controller already established.
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.{Catalog, DedupGate, Install}

  def install(conn, %{"source_tenant_id" => source_tenant_id, "node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id

    case Riptide.WriteRateLimit.check(tenant_id) do
      :deny -> send_resp(conn, 429, "")
      :allow -> handle_install(conn, tenant_id, source_tenant_id, node_id)
    end
  end

  def install(conn, _params), do: send_resp(conn, 400, "")

  def approve(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id
    scope = {:tenant, tenant_id}

    case DedupGate.approve_review(scope, scope, RDF.BlankNode.new(node_id)) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, _reason} -> send_resp(conn, 503, "")
    end
  end

  def decline(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id

    case DedupGate.decline_review({:tenant, tenant_id}, RDF.BlankNode.new(node_id)) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, _reason} -> send_resp(conn, 503, "")
    end
  end

  # A CapabilityCatalogEntry isn't a Rule and doesn't go through Install.install/3's
  # Crosswalk-mapping logic at all — this is copy-on-install instead: fetch the source tenant's own
  # blob bytes and write them into the caller's own tenant-scoped BlobStore, so the installed copy
  # keeps working even if the source tenant's original is later deleted (design spec
  # `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.7).
  def install_capability(conn, %{"source_tenant_id" => source_tenant_id, "node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id

    case Riptide.WriteRateLimit.check(tenant_id) do
      :deny -> send_resp(conn, 429, "")
      :allow -> handle_install_capability(conn, tenant_id, source_tenant_id, node_id)
    end
  end

  def install_capability(conn, _params), do: send_resp(conn, 400, "")

  defp handle_install_capability(conn, tenant_id, source_tenant_id, node_id) do
    {:ok, source_capabilities} = Catalog.list_capabilities({:tenant, source_tenant_id})

    found =
      Enum.find(source_capabilities, fn {node, _entry} -> RDF.BlankNode.value(node) == node_id end)

    case found do
      nil -> send_resp(conn, 404, "")
      {_source_node, entry} -> copy_and_propose(conn, tenant_id, source_tenant_id, entry)
    end
  end

  defp copy_and_propose(conn, tenant_id, source_tenant_id, entry) do
    with {:ok, bytes} <- Riptide.BlobStore.get(source_tenant_id, entry.component_hash),
         {:ok, new_hash} <- Riptide.BlobStore.put(tenant_id, bytes) do
      installed_entry = %{entry | component_hash: new_hash}
      scope = {:tenant, tenant_id}

      respond_propose_capability(
        conn,
        DedupGate.propose_capability(scope, scope, installed_entry, nil)
      )
    else
      _error -> send_resp(conn, 503, "")
    end
  end

  defp respond_propose_capability(conn, {:ok, review_node}) do
    body = Jason.encode!(%{"outcome" => "queued", "node_id" => RDF.BlankNode.value(review_node)})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp respond_propose_capability(conn, {:error, _reason}), do: send_resp(conn, 503, "")

  defp handle_install(conn, tenant_id, source_tenant_id, node_id) do
    {:ok, source_entries} = Catalog.list_entries({:tenant, source_tenant_id})

    found =
      Enum.find(source_entries, fn {node, _rule} -> RDF.BlankNode.value(node) == node_id end)

    case found do
      nil ->
        send_resp(conn, 404, "")

      {source_node, pattern} ->
        {installed_rule, _field_bindings} = Install.install(source_node, pattern, tenant_id)
        scope = {:tenant, tenant_id}

        case DedupGate.propose_install(scope, scope, installed_rule) do
          {:ok, {:queued, node, kind}} ->
            body =
              Jason.encode!(%{
                "outcome" => "queued",
                "kind" => Atom.to_string(kind),
                "node_id" => RDF.BlankNode.value(node)
              })

            conn |> put_resp_content_type("application/json") |> send_resp(200, body)

          {:ok, {:rejected, reason}} ->
            body = Jason.encode!(%{"outcome" => "rejected", "reason" => inspect(reason)})
            conn |> put_resp_content_type("application/json") |> send_resp(200, body)

          {:error, _reason} ->
            send_resp(conn, 503, "")
        end
    end
  end
end
