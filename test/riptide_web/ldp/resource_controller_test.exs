defmodule RiptideWeb.LDP.ResourceControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias RiptideWeb.LDP.ResourceController

  @opts RiptideWeb.Endpoint.init([])

  # Every pre-existing test below exercises anonymous access against a
  # policy-less tenant, exactly as it did before `Authorize` was wired into
  # the router — seed a `:public` allow policy for each fixed tenant_id
  # those tests' own helpers resolve to (`unique_path/0` always uses
  # "test-tenant"; the tenant-isolation test below uses "tenant-a" and
  # "tenant-b" directly) so those tests keep exercising resource behavior,
  # not authorization. The new `describe "authorization"` tests below use
  # their own brand-new, unseeded `authz-e2e-*` tenants instead.
  setup do
    for tenant_id <- ["test-tenant", "tenant-a", "tenant-b"] do
      Riptide.Authz.Store.Placement.add_policy(tenant_id, [], %Riptide.Authz.Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: :public
      })
    end

    :ok
  end

  defp unique_path,
    do: "/tenants/test-tenant/resources/test-#{System.unique_integer([:positive])}"

  # Mirrors RiptideWeb.LDP.ResourceController.stream_id_for/2 so tests can
  # clean up the same Ra-backed stream the controller actually wrote to.
  defp stream_id_for(path) do
    segments = path |> String.trim_leading("/tenants/test-tenant/resources/") |> String.split("/")
    "https://riptide.example/tenants/test-tenant/resources/" <> Enum.join(segments, "/")
  end

  # Same as stream_id_for/1, parameterized by tenant_id, for tests that use
  # a per-test-unique tenant rather than the fixed "test-tenant" literal.
  defp stream_id_for(tenant_id, path) do
    segments =
      path |> String.trim_leading("/tenants/#{tenant_id}/resources/") |> String.split("/")

    "https://riptide.example/tenants/#{tenant_id}/resources/" <> Enum.join(segments, "/")
  end

  test "GET on a resource that was never written to returns 404" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 404
  end

  test "PUT creates a resource, and GET then returns its Turtle state" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)
    turtle = "<https://pod.example/x> <https://pod.example/y> \"z\" .\n"

    put_conn =
      :put
      |> conn(path, turtle)
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 201

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200
    assert get_conn.resp_body =~ "\"z\""
  end

  test "PATCH applies an additive delta on top of existing state" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"1\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body =
      Jason.encode!(%{
        "additions" => "<https://pod.example/x> <https://pod.example/y> \"2\" .\n",
        "removals" => ""
      })

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 200

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.resp_body =~ "\"1\""
    assert get_conn.resp_body =~ "\"2\""
  end

  test "DELETE removes the resource's visible state" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"z\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    delete_conn = :delete |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert delete_conn.status == 204

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.status == 404
  end

  test "PATCH removals actually remove a triple on the next GET" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    :put
    |> conn(path, "<https://s> <https://p> <https://o> .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body =
      Jason.encode!(%{
        "additions" => "",
        "removals" => "<https://s> <https://p> <https://o> .\n"
      })

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 200

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.status == 200
    assert get_conn.resp_body == ""
  end

  test "PUT with an empty body is visible (200, empty) and distinct from DELETE (404)" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    :put
    |> conn(path, "")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.status == 200
    assert get_conn.resp_body == ""

    delete_conn = :delete |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert delete_conn.status == 204

    get_conn2 = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn2.status == 404
  end

  test "PUT with malformed Turtle returns 400 instead of crashing" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    put_conn =
      :put
      |> conn(path, "this is not valid turtle <<<")
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 400
  end

  test "PATCH with malformed Turtle in additions returns 400 instead of crashing" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"1\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body =
      Jason.encode!(%{
        "additions" => "this is not valid turtle <<<",
        "removals" => ""
      })

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 400
  end

  test "PATCH with a missing additions/removals key returns 400 instead of crashing" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"1\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body = Jason.encode!(%{"additions" => ""})

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 400
  end

  test "POST to a container with malformed Turtle returns 400 instead of crashing" do
    container_path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(container_path)) end)

    post_conn =
      :post
      |> conn(container_path, "this is not valid turtle <<<")
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert post_conn.status == 400
  end

  test "POST to a container creates a child resource and records ldp:contains" do
    container_path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(container_path)) end)
    child_turtle = "<https://pod.example/a> <https://pod.example/b> \"c\" .\n"

    post_conn =
      :post
      |> conn(container_path, child_turtle)
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert post_conn.status == 201
    [location] = Plug.Conn.get_resp_header(post_conn, "location")
    assert location =~ container_path
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(location)) end)

    child_get_conn = :get |> conn(location) |> RiptideWeb.Endpoint.call(@opts)
    assert child_get_conn.status == 200
    assert child_get_conn.resp_body =~ "\"c\""

    container_get_conn = :get |> conn(container_path) |> RiptideWeb.Endpoint.call(@opts)
    assert container_get_conn.resp_body =~ "ldp#contains"
  end

  test "ensure_ready_status/1 maps :ok and {:error, _} correctly" do
    assert ResourceController.ensure_ready_status(:ok) == :ok

    assert ResourceController.ensure_ready_status({:error, :cluster_not_formed}) ==
             :error
  end

  test "a %2F-encoded slash inside the tenant_id path segment is rejected with 400, not silently aliased" do
    # Regression test for the stream_id collision finding: plug_cowboy's raw
    # path splitter (deps/plug_cowboy/lib/plug/cowboy/conn.ex) splits on
    # literal "/" bytes with no decoding, so a raw "%2F" stays embedded
    # inside a single path_info element. Phoenix's router
    # (deps/phoenix/lib/phoenix/router.ex) then URI.decodes each already-split
    # segment individually before route param binding, so the decoded
    # ":tenant_id" param ends up containing a literal "/". Without
    # validation, this crafted request would resolve to
    # tenant_id = "a/resources/foo", path_segments = ["x"], producing the
    # exact same stream_id as a legitimate, unrelated request to
    # "/tenants/a/resources/foo/resources/x" for tenant "a" — silently
    # colliding two different tenants onto one stream.
    #
    # Built via Plug.Test.conn/2 (not a hand-constructed conn with tenant_id
    # injected into params) so the raw, still-percent-encoded path is what
    # actually flows through URI.parse/split_path/Phoenix's router, exactly
    # as it would over real HTTP.
    encoded_path = "/tenants/a%2Fresources%2Ffoo/resources/x"

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(
        "https://riptide.example/tenants/a/resources/foo/resources/x"
      )
    end)

    conn = :get |> conn(encoded_path) |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 400
  end

  test "two different tenants requesting the identically-named resource path get fully isolated resources" do
    path_suffix = "shared-name-#{System.unique_integer([:positive])}"
    tenant_a_path = "/tenants/tenant-a/resources/" <> path_suffix
    tenant_b_path = "/tenants/tenant-b/resources/" <> path_suffix

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(
        "https://riptide.example/tenants/tenant-a/resources/" <> path_suffix
      )

      Riptide.RaTestHelpers.cleanup_stream(
        "https://riptide.example/tenants/tenant-b/resources/" <> path_suffix
      )
    end)

    :put
    |> conn(tenant_a_path, "<https://pod.example/x> <https://pod.example/y> \"a\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    get_b_conn = :get |> conn(tenant_b_path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_b_conn.status == 404

    get_a_conn = :get |> conn(tenant_a_path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_a_conn.status == 200
    assert get_a_conn.resp_body =~ "\"a\""
  end

  describe "authorization" do
    test "an anonymous GET of a never-written resource in a brand-new tenant is denied with 403, not 404" do
      tenant_id = "authz-e2e-" <> Uniq.UUID.uuid4()
      path = "/tenants/#{tenant_id}/resources/doc"

      conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "the first authenticated write to a brand-new tenant claims ownership and succeeds" do
      tenant_id = "authz-e2e-" <> Uniq.UUID.uuid4()
      path = "/tenants/#{tenant_id}/resources/doc"
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(tenant_id, path)) end)

      owner_claims = %{"sub" => "owner-" <> Uniq.UUID.uuid4()}
      Application.put_env(:riptide, :authz_test_verifier_claims, owner_claims)
      on_exit(fn -> Application.delete_env(:riptide, :authz_test_verifier_claims) end)

      original_verifier = Application.get_env(:riptide, :auth_verifier)

      Application.put_env(
        :riptide,
        :auth_verifier,
        RiptideWeb.LDP.ResourceControllerTest.StubOwnerVerifier
      )

      on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original_verifier) end)

      put_conn =
        :put
        |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"z\" .\n")
        |> put_req_header("content-type", "text/turtle")
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert put_conn.status == 201

      get_conn =
        :get
        |> conn(path)
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert get_conn.status == 200
      assert get_conn.resp_body =~ "\"z\""
    end

    test "a different identity is denied access to an already-claimed tenant's resource" do
      tenant_id = "authz-e2e-" <> Uniq.UUID.uuid4()
      path = "/tenants/#{tenant_id}/resources/doc"
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(tenant_id, path)) end)

      original_verifier = Application.get_env(:riptide, :auth_verifier)

      Application.put_env(
        :riptide,
        :auth_verifier,
        RiptideWeb.LDP.ResourceControllerTest.StubOwnerVerifier
      )

      on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original_verifier) end)

      :put
      |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"z\" .\n")
      |> put_req_header("content-type", "text/turtle")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

      other_get_conn =
        :get
        |> conn(path)
        |> put_req_header("authorization", "Bearer someone-else-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert other_get_conn.status == 403

      owner_get_conn =
        :get
        |> conn(path)
        |> put_req_header("authorization", "Bearer owner-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert owner_get_conn.status == 200
    end
  end

  # Any bearer token authenticates successfully (so "a different identity"
  # tests exercise Authorize's identity-based denial, not Authenticate's
  # invalid-token 401) — only "owner-token" maps to the tenant's actual
  # owner subject; every other token authenticates as its own distinct,
  # non-owner subject.
  defmodule StubOwnerVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify(token), do: {:ok, %{"sub" => token}}
  end
end
