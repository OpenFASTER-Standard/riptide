defmodule RiptideWeb.Hub.CrosswalkController do
  @moduledoc """
  Propose a Crosswalk and approve/decline it, mirroring
  `RiptideWeb.Hub.ProposeController`/`ReviewController`'s exact shape
  (design spec
  `docs/superpowers/specs/2026-08-30-phase-6i-crosswalks-and-installation-design.md`
  §9).
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
         }
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

        case DedupGate.propose_crosswalk({:tenant, tenant_id}, crosswalk) do
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

  # Explicit case matching, not String.to_existing_atom/1: these atoms
  # otherwise appear nowhere as literals in `lib/` (only in `Crosswalk`'s
  # own `@type`, which typespecs don't reliably intern at runtime) — see
  # `CrosswalkRDFCodec`'s identical `decode_match_type/1` for the full
  # reasoning.
  defp parse_match_type("exact_match"), do: :exact_match
  defp parse_match_type("close_match"), do: :close_match
  defp parse_match_type("broad_match"), do: :broad_match
  defp parse_match_type("narrow_match"), do: :narrow_match
  defp parse_match_type("related_match"), do: :related_match
  defp parse_match_type(_other), do: nil

  def approve(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id

    case DedupGate.approve_crosswalk_review({:tenant, tenant_id}, RDF.BlankNode.new(node_id)) do
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
