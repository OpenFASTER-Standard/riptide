defmodule RiptideWeb.TenantCrosswalkController do
  @moduledoc """
  Propose a Crosswalk into the caller's own tenant Catalog, and approve/decline it — a direct
  Tenant-scoped analogue of the deleted `RiptideWeb.Hub.CrosswalkController` (design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.5).
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.{Crosswalk, DedupGate}

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
           "subject_predicate" => subject_predicate,
           "object_predicate" => object_predicate,
           "match_type" => match_type_string
         } = params
       ) do
    case parse_match_type(match_type_string) do
      nil ->
        send_resp(conn, 400, "")

      match_type ->
        crosswalk = %Crosswalk{
          subject_predicate: RDF.iri(subject_predicate),
          object_predicate: RDF.iri(object_predicate),
          match_type: match_type
        }

        scope = {:tenant, tenant_id}
        replaces = parse_replaces(params)

        case DedupGate.propose_crosswalk(scope, scope, crosswalk, replaces) do
          {:ok, node} ->
            body =
              Jason.encode!(%{"outcome" => "queued", "node_id" => RDF.BlankNode.value(node)})

            conn |> put_resp_content_type("application/json") |> send_resp(200, body)

          {:error, _reason} ->
            send_resp(conn, 503, "")
        end
    end
  end

  defp handle_propose(conn, _tenant_id, _params), do: send_resp(conn, 400, "")

  defp parse_match_type("exact_match"), do: :exact_match
  defp parse_match_type("close_match"), do: :close_match
  defp parse_match_type("broad_match"), do: :broad_match
  defp parse_match_type("narrow_match"), do: :narrow_match
  defp parse_match_type("related_match"), do: :related_match
  defp parse_match_type(_other), do: nil

  defp parse_replaces(%{"replaces" => node_id}) when is_binary(node_id),
    do: RDF.BlankNode.new(node_id)

  defp parse_replaces(_params), do: nil

  def approve(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id
    scope = {:tenant, tenant_id}

    case DedupGate.approve_crosswalk_review(scope, scope, RDF.BlankNode.new(node_id)) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, _reason} -> send_resp(conn, 503, "")
    end
  end

  def decline(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id

    case DedupGate.decline_crosswalk_review({:tenant, tenant_id}, RDF.BlankNode.new(node_id)) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, _reason} -> send_resp(conn, 503, "")
    end
  end
end
