defmodule RiptideWeb.TenantReviewController do
  @moduledoc """
  Approve/decline a Tenant-scope pending review — a direct analogue of
  `RiptideWeb.Hub.ReviewController`, `target_scope`/`review_scope` both `{:tenant, tenant_id}`
  (design spec
  `docs/superpowers/specs/2026-09-01-phase-6m-tenant-execution-surface-design.md` §4.5).
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.DedupGate

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
end
