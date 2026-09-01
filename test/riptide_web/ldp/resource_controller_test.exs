defmodule RiptideWeb.LDP.ResourceControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  import ExUnit.CaptureLog

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.Derivation.{CapabilityCatalogEntry, Catalog}
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
      Store.Placement.add_policy(tenant_id, [], %Policy{
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

  test "GET on a resource that was never written to never creates a placement assignment (atom-exhaustion guard)" do
    path = unique_path()
    stream_id = stream_id_for(path)
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 404
    # StreamSupervisor.ensure_ready/1 (called via current_state/1) mints a
    # permanent BEAM atom and a real 3-member Ra cluster for any stream_id
    # it's asked about — a GET is read-only and must never trigger that for
    # a resource nobody ever wrote to. Placement.lookup/1 is the cheap,
    # atom-free existence signal: nil means ensure_ready/1 was never
    # reached at all for this stream_id.
    assert Riptide.Placement.lookup(stream_id) == nil
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

  test "PUT with a Turtle-star ValidTime annotation round-trips both the base fact and the annotation" do
    path = unique_path()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id_for(path)) end)

    turtle = """
    @prefix ex: <https://pod.example/> .
    @prefix rel: <urn:riptide:relation:> .
    ex:x ex:y "z" {| rel:validFrom "2026-01-01T00:00:00Z"^^<http://www.w3.org/2001/XMLSchema#dateTime> |} .
    """

    put_conn =
      :put
      |> conn(path, turtle)
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 201

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200
    # The base fact stays independently present (unaffected by the
    # annotation, matching every other un-annotated PUT/GET test in this
    # file — proving zero behavior change for callers that never set a
    # ValidTime) ...
    assert get_conn.resp_body =~ "ex:y \"z\""
    # ... and the annotation itself survived the full write/read path.
    assert get_conn.resp_body =~ "validFrom"
    assert get_conn.resp_body =~ "2026-01-01"
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

  test "POST to a container whose containment patch fails cleans up the orphaned child instead of leaving it dangling" do
    container_path = unique_path()
    container_stream_id = stream_id_for(container_path)
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(container_stream_id) end)

    # Pre-seeds the container's placement cache with an unreachable server
    # id — Riptide.Stream.Placement.ensure_started/2's cache-hit path trusts
    # the cache without re-validating reachability, so StreamSupervisor.
    # ensure_ready/1 still reports :ok for the container (the child's own
    # stream is a fresh, real, non-seeded one and succeeds normally), but
    # the container's own StreamServer.append/2 — the containment patch —
    # then genuinely fails against that unreachable address.
    uid = Riptide.RaCluster.uid_for(container_stream_id)
    unreachable_server_id = {String.to_atom(uid), :nonexistent@nohost}
    :ets.insert(:riptide_stream_placement_cache, {container_stream_id, [unreachable_server_id]})

    child_turtle = "<https://pod.example/a> <https://pod.example/b> \"c\" .\n"

    log =
      capture_log(fn ->
        post_conn =
          :post
          |> conn(container_path, child_turtle)
          |> put_req_header("content-type", "text/turtle")
          |> RiptideWeb.Endpoint.call(@opts)

        assert post_conn.status == 503
      end)

    # If cleanup of the orphaned child had ALSO failed, that failure logs
    # loudly (see ResourceController.log_orphaned_child_cleanup_failure/2) —
    # its absence here means the child's own :delete append succeeded, i.e.
    # the orphan was actually cleaned up rather than left dangling.
    refute log =~ "manual cleanup needed"
  end

  describe "reserved path guard" do
    # These requests are expected to be rejected before ever writing
    # anything — cleanup here is defense in depth against a future
    # regression in the guard itself leaving real writes behind on the
    # shared "test-tenant" fixture.
    setup do
      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(
          "https://riptide.example/tenants/test-tenant/resources/jobs"
        )

        Riptide.RaTestHelpers.cleanup_stream(
          "https://riptide.example/tenants/test-tenant/resources/catalog"
        )
      end)

      :ok
    end

    test "PUT /resources/jobs is rejected as a reserved path" do
      conn =
        :put
        |> conn("/tenants/test-tenant/resources/jobs", "")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 409
    end

    test "PATCH /resources/catalog/pending-review is rejected as a reserved path (nested prefix)" do
      body =
        Jason.encode!(%{
          "additions" => "",
          "removals" => ""
        })

      conn =
        :patch
        |> conn("/tenants/test-tenant/resources/catalog/pending-review", body)
        |> put_req_header("content-type", "application/json")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 409
    end

    test "DELETE /resources/catalog is rejected as a reserved path" do
      conn =
        :delete
        |> conn("/tenants/test-tenant/resources/catalog")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 409
    end

    test "POST /resources/jobs (create_child) is rejected as a reserved path" do
      conn =
        :post
        |> conn("/tenants/test-tenant/resources/jobs", "")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 409
    end

    test "GET /resources/jobs is NOT blocked by the reserved-path guard" do
      conn =
        :get
        |> conn("/tenants/test-tenant/resources/jobs")
        |> RiptideWeb.Endpoint.call(@opts)

      # 404 (nothing written yet) is the correct, unblocked read outcome —
      # 409 would mean the guard incorrectly fired on a GET.
      assert conn.status == 404
    end
  end

  describe "stream_id_for/2 and parse_stream_id/1" do
    test "parse_stream_id/1 recovers the exact scope and path_segments stream_id_for/2 was built from" do
      stream_id = ResourceController.stream_id_for({:tenant, "acme"}, ["docs", "sub"])

      assert ResourceController.parse_stream_id(stream_id) ==
               {:ok, {:tenant, "acme"}, ["docs", "sub"]}
    end

    test "parse_stream_id/1 round-trips for a single-segment Tenant path" do
      stream_id = ResourceController.stream_id_for({:tenant, "acme"}, ["doc"])
      assert ResourceController.parse_stream_id(stream_id) == {:ok, {:tenant, "acme"}, ["doc"]}
    end

    test "parse_stream_id/1 round-trips for a Hub path" do
      stream_id = ResourceController.stream_id_for(:hub, ["catalog"])
      assert ResourceController.parse_stream_id(stream_id) == {:ok, :hub, ["catalog"]}
    end

    test "parse_stream_id/1 round-trips for a nested Hub path" do
      stream_id = ResourceController.stream_id_for(:hub, ["catalog", "capabilities"])

      assert ResourceController.parse_stream_id(stream_id) ==
               {:ok, :hub, ["catalog", "capabilities"]}
    end

    test "parse_stream_id/1 returns :error for a stream_id not shaped like a Tenant or Hub resource" do
      assert ResourceController.parse_stream_id("not-a-real-stream-id") == :error
      assert ResourceController.parse_stream_id("https://riptide.example/health") == :error
    end
  end

  test "GET /hub/resources/*path for a never-written Hub resource returns 404" do
    conn =
      :get
      |> conn("/hub/resources/never-written-#{System.unique_integer([:positive])}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 404
  end

  test "GET /hub/resources/*path returns the current state of an admitted Hub Capability" do
    name = "urn:riptide:capability:hubread-#{System.unique_integer([:positive])}"

    entry = %CapabilityCatalogEntry{
      name: RDF.iri(name),
      kind: :effect,
      component_hash: String.duplicate("b", 64),
      function: "run",
      fuel_limit: 10_000_000,
      timeout_ms: 5_000,
      memory_limits: %{
        max_memory_size: nil,
        max_table_elements: nil,
        max_instances: nil,
        max_tables: nil
      }
    }

    # `admit_capability/1` here, not `/2` — Task 6 of this same plan
    # (docs/superpowers/plans/2026-09-01-phase-6n-hub-resource-lifecycle.md)
    # hasn't landed yet at this point in the sequence and will change this
    # to /2 (gaining a `replaces` param); when it does, this call site needs
    # the same update every other `admit_capability/1` caller gets.
    :ok = Catalog.admit_capability(entry)

    conn = :get |> conn("/hub/resources/catalog/capabilities") |> RiptideWeb.Endpoint.call(@opts)
    assert conn.status == 200
    assert conn.resp_body =~ name
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

      Riptide.AppEnvTestHelpers.put_env(
        :riptide,
        :auth_verifier,
        RiptideWeb.LDP.ResourceControllerTest.StubOwnerVerifier
      )

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

      Riptide.AppEnvTestHelpers.put_env(
        :riptide,
        :auth_verifier,
        RiptideWeb.LDP.ResourceControllerTest.StubOwnerVerifier
      )

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
