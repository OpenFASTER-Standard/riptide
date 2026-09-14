defmodule RiptideWeb.BlobControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.Policy

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify("stranger-token"), do: {:ok, %{"sub" => "a-stranger"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  # Stands in for `Riptide.Authz.Store.TenantFacts` so these tests can express tenant membership
  # without standing up a real placement cluster — same shape as `Riptide.AuthzTest`'s own
  # FakeStore. The policies registered by `own_tenant/0` below mirror exactly what
  # `Riptide.Accounts.sign_up/3` writes for a real tenant's owner: allow read/write/invoke at the
  # tenant root (`[]`) for `{:agent, sub}`.
  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies(tenant_id, path_prefix) do
      Agent.get(__MODULE__, &Map.get(&1, {tenant_id, path_prefix}, []))
    end

    @impl true
    def add_policy(tenant_id, path_prefix, policy) do
      Agent.update(
        __MODULE__,
        &Map.update(&1, {tenant_id, path_prefix}, [policy], fn ps -> [policy | ps] end)
      )
    end

    def start do
      case Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)
    FakeStore.start()

    on_exit(fn ->
      if pid = Process.whereis(FakeStore) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp tenant_id, do: "blob-http-test-" <> Uniq.UUID.uuid4()

  # A fresh tenant whose owner policy names `"the-owner"` — the subject `StubVerifier` returns
  # for `"owner-token"`.
  defp own_tenant do
    tenant_id = tenant_id()

    FakeStore.add_policy(tenant_id, [], %Policy{
      effect: :allow,
      modes: [:read, :write, :invoke],
      matcher: {:agent, "the-owner"}
    })

    tenant_id
  end

  defp blob_store_pid do
    case Registry.lookup(Riptide.SupervisedProcess.Registry, "blob_store") do
      [{pid, Riptide.BlobStore}] -> pid
      [] -> nil
    end
  end

  test "PUT then GET round-trips the exact bytes" do
    tenant_id = own_tenant()
    bytes = :crypto.strong_rand_bytes(2048)

    put_conn =
      :put
      |> conn("/tenants/#{tenant_id}/blobs", bytes)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 200
    assert %{"hash" => hash} = Jason.decode!(put_conn.resp_body)

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/blobs/#{hash}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200
    assert get_conn.resp_body == bytes
  end

  test "GET for an unknown hash returns 404" do
    conn =
      :get
      |> conn("/tenants/#{own_tenant()}/blobs/#{String.duplicate("0", 64)}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 404
  end

  test "PUT without a valid token is rejected" do
    conn =
      :put
      |> conn("/tenants/#{own_tenant()}/blobs", "some bytes")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer not-a-real-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 401
  end

  test "PUT without any Authorization header is rejected" do
    conn =
      :put
      |> conn("/tenants/#{own_tenant()}/blobs", "some bytes")
      |> put_req_header("content-type", "application/octet-stream")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 401
  end

  test "GET without any Authorization header is rejected" do
    conn =
      :get
      |> conn("/tenants/#{own_tenant()}/blobs/#{String.duplicate("0", 64)}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 401
  end

  test "PUT with large body over 8MB round-trips correctly" do
    tenant_id = own_tenant()
    bytes = :crypto.strong_rand_bytes(9 * 1024 * 1024)

    put_conn =
      :put
      |> conn("/tenants/#{tenant_id}/blobs", bytes)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 200
    assert %{"hash" => hash} = Jason.decode!(put_conn.resp_body)

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/blobs/#{hash}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200
    assert get_conn.resp_body == bytes
  end

  # Regression: an unvalidated `:hash` used to be forwarded straight into
  # `Riptide.BlobStore.get/2`, whose `path_for/2` pattern-matches
  # `<<prefix::binary-size(2), rest::binary>> = hash`. Anything under 2 bytes raised a
  # `MatchError` *inside the BlobStore GenServer*, and repeating it a handful of times within the
  # `DynamicSupervisor`'s restart-intensity window left blob storage dead node-wide until a full
  # node restart. The pid assertions are what actually prove the fix: the store process is never
  # touched at all for a malformed hash, so there is nothing to crash.
  describe "malformed :hash never reaches the BlobStore GenServer" do
    for {label, hash} <- [
          {"single character", "a"},
          {"empty-ish dot", "."},
          {"uppercase hex", String.duplicate("A", 64)},
          {"too short", "abc"},
          {"too long", String.duplicate("a", 65)},
          {"non-hex", String.duplicate("z", 64)},
          {"path traversal", "..%2F..%2Fetc%2Fpasswd"}
        ] do
      test "#{label} returns 404 without disturbing the store" do
        tenant_id = own_tenant()
        pid_before = blob_store_pid()
        assert is_pid(pid_before) and Process.alive?(pid_before)

        conn =
          :get
          |> conn("/tenants/#{tenant_id}/blobs/#{unquote(hash)}")
          |> put_req_header("authorization", "Bearer owner-token")
          |> RiptideWeb.Endpoint.call(@opts)

        assert conn.status == 404

        # Same pid, still alive: no crash, no supervisor restart, no state change.
        assert blob_store_pid() == pid_before
        assert Process.alive?(pid_before)
      end
    end

    test "repeating a malformed hash many times in a row leaves the store healthy" do
      tenant_id = own_tenant()
      pid_before = blob_store_pid()

      for _ <- 1..20 do
        conn =
          :get
          |> conn("/tenants/#{tenant_id}/blobs/a")
          |> put_req_header("authorization", "Bearer owner-token")
          |> RiptideWeb.Endpoint.call(@opts)

        assert conn.status == 404
      end

      assert blob_store_pid() == pid_before
      assert Process.alive?(pid_before)

      # And the store still actually works afterward.
      put_conn =
        :put
        |> conn("/tenants/#{tenant_id}/blobs", "still working")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert put_conn.status == 200
    end
  end

  describe "tenant membership" do
    test "a member of the tenant can PUT and GET (same-tenant success)" do
      tenant_id = own_tenant()

      put_conn =
        :put
        |> conn("/tenants/#{tenant_id}/blobs", "members only")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert put_conn.status == 200
      %{"hash" => hash} = Jason.decode!(put_conn.resp_body)

      get_conn =
        :get
        |> conn("/tenants/#{tenant_id}/blobs/#{hash}")
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert get_conn.status == 200
      assert get_conn.resp_body == "members only"
    end

    test "a valid token for a different tenant cannot GET this tenant's blobs" do
      victim_tenant = own_tenant()

      put_conn =
        :put
        |> conn("/tenants/#{victim_tenant}/blobs", "tenant A's secret")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert put_conn.status == 200
      %{"hash" => hash} = Jason.decode!(put_conn.resp_body)

      # "stranger-token" is a perfectly valid token (`:auth` accepts it) — it just belongs to a
      # subject with no policy in this tenant. Before the membership check this returned 200.
      get_conn =
        :get
        |> conn("/tenants/#{victim_tenant}/blobs/#{hash}")
        |> put_req_header("authorization", "Bearer stranger-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert get_conn.status == 403
    end

    test "a valid token for a different tenant cannot PUT into this tenant" do
      victim_tenant = own_tenant()

      conn =
        :put
        |> conn("/tenants/#{victim_tenant}/blobs", "not yours")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer stranger-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
    end
  end

  describe "tenant_id path traversal" do
    test "a tenant_id of `..` is rejected and writes nothing outside the blob data dir" do
      bytes = "escaping the data dir"
      hash = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      <<prefix::binary-size(2), rest::binary>> = hash

      # Exactly what `Riptide.BlobStore.path_for("..", hash)` would resolve to:
      # `Path.join(["priv/blob_data", "..", prefix, rest])` — i.e. `priv/<prefix>/<rest>`, one
      # directory *above* the blob data dir. Confirmed live against the pre-fix controller: this
      # file really was created.
      data_dir = Application.get_env(:riptide, :blob_data_dir) || "priv/blob_data"
      escape_dir = Path.join(Path.dirname(data_dir), prefix)
      escape_path = Path.join(escape_dir, rest)
      File.rm_rf!(escape_path)

      conn =
        :put
        |> conn("/tenants/../blobs", bytes)
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      # 400 (this controller's own guard) is what the fix produces; anything in the 4xx range is
      # acceptable as long as nothing was written outside the data dir.
      assert conn.status in 400..499
      refute File.exists?(escape_path)
    end

    test "a tenant_id of `.` is rejected" do
      conn =
        :get
        |> conn("/tenants/./blobs/#{String.duplicate("0", 64)}")
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status in 400..499
    end
  end
end
