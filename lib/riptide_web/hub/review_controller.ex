defmodule RiptideWeb.Hub.ReviewController do
  @moduledoc """
  Approve/decline a Hub-bound pending review — the *proposing* Tenant's
  own review-queue authorization, unchanged from every other tenant-
  scoped write (design spec
  `docs/superpowers/specs/2026-08-29-phase-6h-ii-pattern-hub-deployment-design.md`
  §2, §5, §6).
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.DedupGate

  def approve(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id

    case DedupGate.approve_review(:hub, {:tenant, tenant_id}, RDF.BlankNode.new(node_id)) do
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
