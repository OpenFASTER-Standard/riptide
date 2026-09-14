defmodule RiptideWeb.BlobController do
  @moduledoc """
  Authenticated, tenant-scoped HTTP surface over `Riptide.BlobStore` — see design spec
  `docs/superpowers/specs/2026-09-14-riptide-euro-office-bridge-design.md` §5.3.

  `Riptide.BlobStore.put/2`/`get/2` perform no authorization of their own (see that module's own
  moduledoc), and these two routes deliberately skip the `:authz` pipeline plug: that plug
  evaluates the *request path*'s own segments, which for a blob route would be a content hash,
  not a resource path anybody could ever have written a policy about. So this controller does its
  own checks, and it is the only thing standing between a caller and the blob store. Exactly
  three protections exist here, no more:

  1. **Authentication** (`:auth` pipeline plug, `RiptideWeb.Plugs.Authenticate`) — the bearer
     token's signature and claims are valid. That is *all* `:auth` establishes; it says nothing
     about which tenant the token's subject belongs to.
  2. **Tenant membership** (`authorize/2` below) — `Riptide.Authz.evaluate_with_matcher/4`
     evaluated at the tenant *root* (`[]`, no path segments), which is exactly where
     `Riptide.Accounts.sign_up/3` writes the tenant's owner policy. This is a membership check,
     not a path-based one: it asks "may this subject read/write this tenant at all," which is the
     only question a content-addressed blob route can meaningfully ask. Without it, a token
     issued for tenant A could read and write tenant B's blobs.
  3. **Input validation** (`safe_tenant_id?/1`, `valid_hash?/1`) — the `tenant_id` and `hash`
     path segments both reach the filesystem through `Riptide.BlobStore.path_for/2`. A
     `tenant_id` of `.`/`..` (which `RiptideWeb.Plugs.ResolveTenant`'s own `[A-Za-z0-9._-]` guard
     permits) escapes the blob data directory, and a `hash` shorter than 2 bytes is a `MatchError`
     *inside the BlobStore GenServer itself* (`<<prefix::binary-size(2), rest::binary>> = hash`),
     which repeated a few times exceeds the `DynamicSupervisor`'s restart intensity and leaves
     blob storage dead node-wide until a full node restart. Both are rejected before any
     `BlobStore` call is made.

  Notably *not* provided here: any per-blob or per-document authorization. Any member of a tenant
  can read any blob in that tenant, and write new ones.
  """

  use Phoenix.Controller, formats: [:json]

  # `Riptide.BlobStore.hash_of/1` is `Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)`,
  # so every hash the store itself ever produces is exactly 64 lowercase hex characters. Anything
  # else cannot name an existing blob, and must never reach `BlobStore.get/2` — see the moduledoc.
  @hash_format ~r/\A[0-9a-f]{64}\z/

  def create(conn, _params) do
    with :ok <- require_authenticated(conn),
         {:ok, tenant_id} <- require_safe_tenant_id(conn),
         :ok <- authorize(conn, tenant_id, :write) do
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
    else
      {:error, status} -> send_resp(conn, status, "")
    end
  end

  def show(conn, %{"hash" => hash}) do
    with :ok <- require_authenticated(conn),
         {:ok, tenant_id} <- require_safe_tenant_id(conn),
         :ok <- authorize(conn, tenant_id, :read),
         :ok <- require_valid_hash(hash) do
      case Riptide.BlobStore.get(tenant_id, hash) do
        {:ok, bytes} ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> send_resp(200, bytes)

        {:error, :not_found} ->
          send_resp(conn, 404, "")
      end
    else
      {:error, status} -> send_resp(conn, status, "")
    end
  end

  defp require_authenticated(conn) do
    if is_nil(conn.assigns[:current_subject]), do: {:error, 401}, else: :ok
  end

  # `RiptideWeb.Plugs.ResolveTenant` is what resolves and assigns this (every other tenant-scoped
  # controller in this repo reads `conn.assigns.tenant_id`, never `params["tenant_id"]`), but its
  # own `[A-Za-z0-9._-]+` charset guard deliberately permits `.` and `..` — harmless for the
  # stream-id string concatenation it was written to protect, a real directory traversal here,
  # where the value is a path component on disk. Confirmed live before this guard existed:
  # `PUT /tenants/../blobs` wrote to `priv/ad/<hash>` instead of `priv/blob_data/../...`.
  defp require_safe_tenant_id(conn) do
    tenant_id = conn.assigns[:tenant_id]

    if is_binary(tenant_id) and safe_tenant_id?(tenant_id) do
      {:ok, tenant_id}
    else
      {:error, 400}
    end
  end

  defp safe_tenant_id?(tenant_id) do
    tenant_id not in [".", ".."] and not String.contains?(tenant_id, ["/", "\\"])
  end

  defp require_valid_hash(hash) do
    if is_binary(hash) and Regex.match?(@hash_format, hash), do: :ok, else: {:error, 404}
  end

  # Mirrors `RiptideWeb.Plugs.Authorize`'s own rescue/catch: `Riptide.Authz.evaluate_with_matcher/4`
  # can raise or exit when the placement cluster backing the policy store is fully unreachable, and
  # a caller/load-balancer needs to tell that transient failure apart from a genuine 403.
  defp authorize(conn, tenant_id, mode) do
    case Riptide.Authz.evaluate_with_matcher(
           {:tenant, tenant_id},
           [],
           conn.assigns[:current_subject],
           mode
         ) do
      {:allow, _matcher} -> :ok
      :deny -> {:error, 403}
    end
  rescue
    _ -> {:error, 503}
  catch
    :exit, _ -> {:error, 503}
  end

  defp read_full_body(conn, acc \\ <<>>) do
    case Plug.Conn.read_body(conn) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_full_body(conn, acc <> data)
    end
  end
end
