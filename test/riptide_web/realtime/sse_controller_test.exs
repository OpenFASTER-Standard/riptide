defmodule RiptideWeb.Realtime.SseControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test
  require Logger

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("valid-token"), do: {:ok, %{"sub" => "user-1"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  # The two top-level tests below (not inside any `describe` block) predate
  # authorization being enforced and use fixed tenants of their own
  # (`unique_stream_id/0`'s "sse-test-tenant", and the gap test's
  # "sse-gap-test-tenant") — seed a `:public`, `[:read]` policy for each so
  # authorization now being enforced doesn't change their expected statuses,
  # same pattern as `resource_controller_test.exs`'s Task 5 setup.
  setup do
    for tenant_id <- ["sse-test-tenant", "sse-gap-test-tenant"] do
      Store.Placement.add_policy(tenant_id, [], %Policy{
        effect: :allow,
        modes: [:read],
        matcher: :public
      })
    end

    :ok
  end

  defp unique_stream_id,
    do:
      ResourceController.stream_id_for("sse-test-tenant", [
        "doc-#{System.unique_integer([:positive])}"
      ])

  # A tenant-resource-shaped stream_id (not just an opaque literal like
  # `unique_stream_id/0` above), so `SseController.subscribe/2`'s new
  # authorization check can resolve it to a tenant. Fixed tenant, unique
  # path segment per call — mirrors `resource_controller_test.exs`'s fixed
  # "test-tenant" pattern (Task 5), with the matching policy seeded in the
  # "authentication" describe block's own `setup` below.
  defp unique_auth_stream_id,
    do:
      ResourceController.stream_id_for("sse-auth-test-tenant", [
        "doc-#{System.unique_integer([:positive])}"
      ])

  test "subscribing with no Last-Event-ID and then appending pushes one SSE frame" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)

    task =
      Task.async(fn ->
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)
      end)

    # A fixed sleep can't reliably outlast however long the async Task
    # takes to reach its own Phoenix.PubSub.subscribe/2 call under a busier
    # scheduler (seen on CI) — appending before that subscribe registers
    # means the event is published before anyone's listening and silently
    # missed. Phoenix.PubSub.subscribe/3 registers via `Registry.register/3`
    # on the pubsub itself, so polling `Registry.lookup/2` for this topic is
    # a direct, non-sleep-based signal that the subscription is live.
    assert eventually(fn -> Registry.lookup(Riptide.PubSub, "stream:" <> stream_id) != [] end)
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    conn = Task.await(task, 3_000)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ "id: 1\n"
  end

  test "subscribing with a cursor older than the retention window returns 409 with a gap signal" do
    stream_id =
      ResourceController.stream_id_for("sse-gap-test-tenant", [
        "doc-#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    {:ok, _pid} = StreamServer.start_link({stream_id, retention: 1})

    StreamServer.append(
      stream_id,
      Event.new(stream_id, :replace, RDF.Graph.new())
    )

    StreamServer.append(
      stream_id,
      Event.new(stream_id, :replace, RDF.Graph.new())
    )

    conn =
      :get
      |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
      |> put_req_header("last-event-id", "0")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body) == %{"oldestAvailable" => 2}
  end

  describe "authentication" do
    # These pre-existing tests exercise *authentication* behavior against a
    # tenant-shaped stream_id with no bearing on authorization — seed a
    # `:public`, `[:read]` policy for that fixed tenant (same pattern as
    # `resource_controller_test.exs`'s Task 5 setup) so authorization now
    # being enforced doesn't change their expected statuses.
    setup do
      Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)

      Store.Placement.add_policy("sse-auth-test-tenant", [], %Policy{
        effect: :allow,
        modes: [:read],
        matcher: :public
      })

      :ok
    end

    test "subscribing with no token still succeeds (optional auth)" do
      stream_id = unique_auth_stream_id()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
      StreamSupervisor.ensure_ready(stream_id)

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 200
    end

    test "subscribing with a valid ?token= query param succeeds" do
      stream_id = unique_auth_stream_id()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
      StreamSupervisor.ensure_ready(stream_id)

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe?token=valid-token")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 200
    end

    test "subscribing with an invalid token is rejected with 401 before touching the stream" do
      stream_id = unique_auth_stream_id()

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe?token=garbage")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 401
    end
  end

  describe "new-stream rate limiting (atom-exhaustion guard)" do
    setup do
      Riptide.AppEnvTestHelpers.put_env(:riptide, :new_stream_rate_limit, 2)

      Store.Placement.add_policy("sse-ratelimit-test-tenant", [], %Policy{
        effect: :allow,
        modes: [:read],
        matcher: :public
      })

      :ok
    end

    defp new_ratelimit_stream_id do
      ResourceController.stream_id_for("sse-ratelimit-test-tenant", [
        "doc-#{System.unique_integer([:positive])}"
      ])
    end

    test "subscribing to more distinct brand-new streams than the configured limit is rejected with 429" do
      subject = "ratelimit-subject-" <> Uniq.UUID.uuid4()

      Riptide.AppEnvTestHelpers.put_env(
        :riptide,
        :auth_verifier,
        RiptideWeb.Realtime.SseControllerTest.FixedSubjectVerifier
      )

      Application.put_env(:riptide, :ratelimit_test_subject, subject)
      on_exit(fn -> Application.delete_env(:riptide, :ratelimit_test_subject) end)

      stream_ids = for _ <- 1..3, do: new_ratelimit_stream_id()

      for stream_id <- stream_ids,
          do: on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

      statuses =
        for stream_id <- stream_ids do
          :get
          |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
          |> put_req_header("authorization", "Bearer any-token")
          |> RiptideWeb.Endpoint.call(@opts)
          |> Map.fetch!(:status)
        end

      assert statuses == [200, 200, 429]
    end

    test "subscribing to an already-existing stream is never rate-limited, regardless of volume" do
      subject = "ratelimit-subject-" <> Uniq.UUID.uuid4()

      Riptide.AppEnvTestHelpers.put_env(
        :riptide,
        :auth_verifier,
        RiptideWeb.Realtime.SseControllerTest.FixedSubjectVerifier
      )

      Application.put_env(:riptide, :ratelimit_test_subject, subject)
      on_exit(fn -> Application.delete_env(:riptide, :ratelimit_test_subject) end)

      stream_id = new_ratelimit_stream_id()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
      StreamSupervisor.ensure_ready(stream_id)

      # 3 subscribes to the SAME already-existing stream — one more than the
      # limit of 2 configured above — must all succeed, since only creating
      # a BRAND NEW stream is rate-limited, never reading an existing one.
      statuses =
        for _ <- 1..3 do
          :get
          |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
          |> put_req_header("authorization", "Bearer any-token")
          |> RiptideWeb.Endpoint.call(@opts)
          |> Map.fetch!(:status)
        end

      assert statuses == [200, 200, 200]
    end
  end

  # Every token authenticates as the SAME configured test subject, regardless
  # of the token's actual value — lets the rate-limiting tests above drive
  # every subscribe attempt as one consistent subject without needing a real
  # JWT for each request.
  defmodule FixedSubjectVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify(_token) do
      {:ok, %{"sub" => Application.fetch_env!(:riptide, :ratelimit_test_subject)}}
    end
  end

  describe "authorization" do
    test "subscribing to a stream_id shaped like a tenant resource with no matching policy is denied with 403" do
      tenant_id = "sse-authz-test-" <> Uniq.UUID.uuid4()
      stream_id = ResourceController.stream_id_for(tenant_id, ["doc"])

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "subscribing to a stream_id shaped like a tenant resource with a public read policy succeeds" do
      tenant_id = "sse-authz-test-" <> Uniq.UUID.uuid4()
      stream_id = ResourceController.stream_id_for(tenant_id, ["doc"])
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

      :ok =
        Store.Placement.add_policy(tenant_id, [], %Policy{
          effect: :allow,
          modes: [:read],
          matcher: :public
        })

      StreamSupervisor.ensure_ready(stream_id)

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 200
    end

    test "a stream_id not shaped like a tenant resource (e.g. a legacy non-tenant-scoped id) is denied, not crashed" do
      conn =
        :get
        |> conn("/streams/some-legacy-stream-id/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "sets tenant_id in Logger metadata even when authorization denies the request" do
      tenant_id = "sse-authz-test-" <> Uniq.UUID.uuid4()
      stream_id = ResourceController.stream_id_for(tenant_id, ["doc"])

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
      assert Logger.metadata()[:tenant_id] == tenant_id
    end

    # Riptide.Authz.evaluate/4 (called directly here, not through
    # RiptideWeb.Plugs.Authorize) raises when the placement cluster backing
    # the policy store is totally unreachable — this must surface as a
    # clean 503 (retry-able), not an uncaught crash / generic 500.
    test "subscribing when the placement cluster is fully unreachable returns 503, not a crash" do
      Riptide.AppEnvTestHelpers.put_env(:riptide, :placement_members_override, [
        :nonexistent@nohost
      ])

      tenant_id = "sse-authz-down-test-" <> Uniq.UUID.uuid4()
      stream_id = ResourceController.stream_id_for(tenant_id, ["doc"])

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 503
    end
  end

  defp eventually(fun, attempts_left \\ 50) do
    cond do
      fun.() ->
        true

      attempts_left <= 1 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts_left - 1)
    end
  end
end
