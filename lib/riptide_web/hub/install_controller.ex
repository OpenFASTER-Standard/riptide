defmodule RiptideWeb.Hub.InstallController do
  @moduledoc """
  Install a Hub entry into the requesting Tenant's own Catalog (design
  spec
  `docs/superpowers/specs/2026-08-30-phase-6i-crosswalks-and-installation-design.md`
  §9). `target_scope`/`review_scope` are always the same
  `{:tenant, tenant_id}` — installation writes into and is reviewed by
  the installing Tenant's own Catalog, never `:hub`. Approval/decline
  live on this controller too (`/hub/install-reviews/:node_id/...`), not
  `RiptideWeb.Hub.ReviewController` — see `approve/2`'s own doc for why.
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.{Catalog, DedupGate, Install}

  def install(conn, %{"hub_node_id" => hub_node_id}) do
    tenant_id = conn.assigns.tenant_id

    case Riptide.HubRateLimit.check_propose(tenant_id) do
      :deny -> send_resp(conn, 429, "")
      :allow -> handle_install(conn, tenant_id, hub_node_id)
    end
  end

  def install(conn, _params), do: send_resp(conn, 400, "")

  @doc """
  Approve/decline an install-created pending review. Deliberately a
  *separate* route from `RiptideWeb.Hub.ReviewController`'s
  `/hub/pending-reviews/:node_id/approve` — that controller hardcodes
  `target_scope: :hub` (correct for 6h-ii's Hub-propose flow, where
  target_scope is always `:hub` regardless of review_scope), which would
  silently admit an installed, possibly Crosswalk-rewritten, per-Tenant
  Rule into the *global* Hub catalog instead of the installing Tenant's
  own — Install's target_scope is always `{:tenant, tenant_id}` (§9).
  """
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

  defp handle_install(conn, tenant_id, hub_node_id) do
    {:ok, hub_entries} = Catalog.list_entries(:hub)

    found =
      Enum.find(hub_entries, fn {node, _rule} -> RDF.BlankNode.value(node) == hub_node_id end)

    case found do
      nil ->
        send_resp(conn, 404, "")

      {hub_node, pattern} ->
        {installed_rule, _field_bindings} = Install.install(hub_node, pattern, tenant_id)
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
