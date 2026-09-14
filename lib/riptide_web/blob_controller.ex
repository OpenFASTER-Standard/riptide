defmodule RiptideWeb.BlobController do
  @moduledoc """
  Authenticated, tenant-scoped HTTP surface over `Riptide.BlobStore` — see design spec
  `docs/superpowers/specs/2026-09-14-riptide-euro-office-bridge-design.md` §5.3.
  `Riptide.BlobStore.put/2`/`get/2` perform no authorization of their own (see that module's
  own moduledoc); the `:auth` pipeline plug is what makes these routes safe to expose.
  """

  use Phoenix.Controller, formats: [:json]

  def create(conn, %{"tenant_id" => tenant_id}) do
    if is_nil(conn.assigns[:current_subject]) do
      send_resp(conn, 401, "")
    else
      {:ok, bytes, conn} = read_full_body(conn)

      case Riptide.BlobStore.put(tenant_id, bytes) do
        {:ok, hash} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"hash" => hash}))

        {:error, reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(500, Jason.encode!(%{"error" => 1, "message" => inspect(reason)}))
      end
    end
  end

  def show(conn, %{"tenant_id" => tenant_id, "hash" => hash}) do
    if is_nil(conn.assigns[:current_subject]) do
      send_resp(conn, 401, "")
    else
      case Riptide.BlobStore.get(tenant_id, hash) do
        {:ok, bytes} ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> send_resp(200, bytes)

        {:error, :not_found} ->
          send_resp(conn, 404, "")
      end
    end
  end

  defp read_full_body(conn, acc \\ <<>>) do
    case Plug.Conn.read_body(conn) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_full_body(conn, acc <> data)
    end
  end
end
