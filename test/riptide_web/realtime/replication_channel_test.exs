defmodule RiptideWeb.Realtime.ReplicationChannelTest do
  # :auth_verifier is global Application state (mutated in setup/0 below) —
  # every other consumer of it (authenticate_test.exs, policy_controller_test.exs,
  # sse_controller_test.exs, authz_test.exs, ldp/resource_controller_test.exs)
  # is async: false for the same reason; this file matches that convention
  # rather than risking another async test transiently observing StubVerifier.
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  require Logger

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.Event
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController
  alias RiptideWeb.Realtime.{ReplicationChannel, Socket}

  @endpoint RiptideWeb.Endpoint

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("valid-token"), do: {:ok, %{"sub" => "user-1"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:riptide, :auth_verifier)
    Application.put_env(:riptide, :auth_verifier, StubVerifier)
    on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original) end)
    :ok
  end

  # The pre-existing tests below (predating authorization) use
  # `unique_stream_id/0`'s fixed tenant ("ws-test-tenant") and no bearing on
  # authorization itself — seed a `:public`, `[:read]` policy for it so
  # authorization now being enforced doesn't change their expected outcomes,
  # same pattern as `sse_controller_test.exs`'s Task 7 setup.
  setup do
    Store.Placement.add_policy("ws-test-tenant", [], %Policy{
      effect: :allow,
      modes: [:read],
      matcher: :public
    })

    :ok
  end

  # A tenant-resource-shaped stream_id (not an opaque literal like the old
  # `"ws-test-<n>"` ids), so `ReplicationChannel.join/3`'s authorization
  # check can resolve it to a tenant. Fixed tenant, unique path segment per
  # call — mirrors `sse_controller_test.exs`'s `unique_stream_id/0`.
  defp unique_stream_id,
    do:
      ResourceController.stream_id_for("ws-test-tenant", [
        "doc-#{System.unique_integer([:positive])}"
      ])

  test "joining with after: 0 receives no backlog on an empty stream" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)

    {:ok, socket} = connect(Socket, %{})

    {:ok, reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    assert reply == %{"backlog" => []}
  end

  test "joining with after: 0 on a non-empty stream replies with the existing backlog" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    {:ok, socket} = connect(Socket, %{})

    {:ok, reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    assert %{"backlog" => [%{"cursor" => 1}]} = reply
  end

  test "joining with a cursor older than the retention window is rejected with a gap" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    {:ok, _pid} = StreamServer.start_link({stream_id, retention: 1})
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    {:ok, socket} = connect(Socket, %{})

    assert {:error, %{"oldestAvailable" => 2}} =
             subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{
               "after" => 0
             })
  end

  test "new appends after joining are pushed as replication_frame messages" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)

    {:ok, socket} = connect(Socket, %{})

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    StreamServer.append(
      stream_id,
      Event.new(stream_id, :patch, %Patch{additions: [], removals: []})
    )

    assert_push "replication_frame", %{
      "cursor" => 1,
      "event" => %{
        "sequence" => 1,
        "streamId" => ^stream_id,
        "isSnapshot" => false
      }
    }
  end

  # `assert_push`/`refute_push` scope to the calling *process*'s mailbox, not
  # to a particular socket: `Phoenix.ChannelTest.__connect__/4` sets
  # `transport_pid: self()` at connect time, and `assert_push`/`refute_push`
  # match on event+payload only (not topic) against whatever lands in that
  # mailbox (see `deps/phoenix/lib/phoenix/test/channel_test.ex`). Two
  # sockets connected from the same test process therefore share one
  # mailbox, and a push meant for either one satisfies `assert_push`/
  # `refute_push` run from that process — proven live: appending to the
  # *wrong* stream still made the naive single-process version of this test
  # pass (a false pass), because `assert_push` matched socket B's push and
  # `refute_push` then trivially found nothing left to match. Joining
  # socket B from a separate `Task` gives it its own `transport_pid`/
  # mailbox, so `refute_push` in the task can only match a push actually
  # delivered to socket B.
  test "an append to stream A is not pushed to a socket joined to stream B" do
    stream_a = unique_stream_id()
    stream_b = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_a) end)
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_b) end)

    test_pid = self()

    task_b =
      Task.async(fn ->
        {:ok, socket_b} = connect(Socket, %{}, test_process: test_pid)

        {:ok, _reply, _socket_b} =
          subscribe_and_join(socket_b, ReplicationChannel, "replication:" <> stream_b, %{
            "after" => 0
          })

        send(test_pid, :socket_b_joined)

        refute_push "replication_frame", %{}, 400
      end)

    {:ok, socket_a} = connect(Socket, %{})

    {:ok, _reply, _socket_a} =
      subscribe_and_join(socket_a, ReplicationChannel, "replication:" <> stream_a, %{"after" => 0})

    assert_receive :socket_b_joined, 500

    StreamSupervisor.ensure_ready(stream_a)
    StreamServer.append(stream_a, Event.new(stream_a, :replace, RDF.Graph.new()))

    assert_push "replication_frame", %{}, 500

    Task.await(task_b)
  end

  test "connecting with no auth_token still succeeds, current_subject is nil" do
    assert {:ok, socket} = connect(Socket, %{})
    assert socket.assigns.current_subject == nil
  end

  test "connecting with a valid auth_token assigns current_subject" do
    assert {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: "valid-token"})
    assert socket.assigns.current_subject == %{"sub" => "user-1"}
  end

  test "connecting with an invalid auth_token is refused" do
    assert {:error, _reason} = connect(Socket, %{}, connect_info: %{auth_token: "garbage"})
  end

  test "joining a topic shaped like a tenant resource with no matching policy is denied, not crashed" do
    tenant_id = "ws-authz-test-" <> Uniq.UUID.uuid4()
    stream_id = ResourceController.stream_id_for(tenant_id, ["doc"])

    {:ok, socket} = connect(Socket, %{})

    assert {:error, %{"reason" => "unauthorized"}} =
             subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{
               "after" => 0
             })
  end

  test "joining a topic shaped like a tenant resource with a public read policy succeeds" do
    tenant_id = "ws-authz-test-" <> Uniq.UUID.uuid4()
    stream_id = ResourceController.stream_id_for(tenant_id, ["doc"])
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    :ok =
      Store.Placement.add_policy(tenant_id, [], %Policy{
        effect: :allow,
        modes: [:read],
        matcher: :public
      })

    StreamSupervisor.ensure_ready(stream_id)

    {:ok, socket} = connect(Socket, %{})

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})
  end

  test "joining a topic not shaped like a tenant resource is denied, not crashed" do
    {:ok, socket} = connect(Socket, %{})

    assert {:error, %{"reason" => "unauthorized"}} =
             subscribe_and_join(
               socket,
               ReplicationChannel,
               "replication:some-legacy-stream-id",
               %{
                 "after" => 0
               }
             )
  end

  test "sets tenant_id in Logger metadata after a successful join" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)

    {:ok, socket} = connect(Socket, %{})

    # Calls join/3 DIRECTLY (not via Phoenix.ChannelTest.join/4 or
    # subscribe_and_join/4) — those helpers run the channel callback in a
    # separate, GenServer-spawned process, so Logger.metadata set inside it
    # would be invisible here. join/3 is a plain exported function; nothing
    # about its body is channel-process-specific.
    {:ok, _reply, _socket} =
      ReplicationChannel.join("replication:" <> stream_id, %{"after" => 0}, socket)

    assert Logger.metadata()[:tenant_id] == "ws-test-tenant"
  end

  test "sets subject in Logger metadata after a successful join when the socket has a subject" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)

    {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: "valid-token"})

    {:ok, _reply, _socket} =
      ReplicationChannel.join("replication:" <> stream_id, %{"after" => 0}, socket)

    assert Logger.metadata()[:subject] == "user-1"
  end

  describe "new-stream rate limiting (atom-exhaustion guard)" do
    setup do
      original_limit = Application.get_env(:riptide, :new_stream_rate_limit)
      Application.put_env(:riptide, :new_stream_rate_limit, 2)
      on_exit(fn -> Application.put_env(:riptide, :new_stream_rate_limit, original_limit) end)

      Store.Placement.add_policy("ws-ratelimit-test-tenant", [], %Policy{
        effect: :allow,
        modes: [:read],
        matcher: :public
      })

      :ok
    end

    defp new_ratelimit_stream_id do
      ResourceController.stream_id_for("ws-ratelimit-test-tenant", [
        "doc-#{System.unique_integer([:positive])}"
      ])
    end

    test "joining more distinct brand-new streams than the configured limit is rejected" do
      subject = "ratelimit-subject-" <> Uniq.UUID.uuid4()
      original_verifier = Application.get_env(:riptide, :auth_verifier)

      Application.put_env(
        :riptide,
        :auth_verifier,
        RiptideWeb.Realtime.ReplicationChannelTest.FixedSubjectVerifier
      )

      on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original_verifier) end)
      Application.put_env(:riptide, :ratelimit_test_subject, subject)
      on_exit(fn -> Application.delete_env(:riptide, :ratelimit_test_subject) end)

      {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: "any-token"})

      stream_ids = for _ <- 1..3, do: new_ratelimit_stream_id()

      for stream_id <- stream_ids,
          do: on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

      outcomes =
        for stream_id <- stream_ids do
          case subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{
                 "after" => 0
               }) do
            {:ok, _reply, _socket} -> :ok
            {:error, %{"reason" => "rate_limited"}} -> :rate_limited
          end
        end

      assert outcomes == [:ok, :ok, :rate_limited]
    end

    test "joining an already-existing stream is never rate-limited, regardless of volume" do
      subject = "ratelimit-subject-" <> Uniq.UUID.uuid4()
      original_verifier = Application.get_env(:riptide, :auth_verifier)

      Application.put_env(
        :riptide,
        :auth_verifier,
        RiptideWeb.Realtime.ReplicationChannelTest.FixedSubjectVerifier
      )

      on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original_verifier) end)
      Application.put_env(:riptide, :ratelimit_test_subject, subject)
      on_exit(fn -> Application.delete_env(:riptide, :ratelimit_test_subject) end)

      stream_id = new_ratelimit_stream_id()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
      StreamSupervisor.ensure_ready(stream_id)

      # 3 joins to the SAME already-existing stream — one more than the
      # limit of 2 configured above — must all succeed, since only creating
      # a BRAND NEW stream is rate-limited, never reading an existing one.
      # Each join needs its own socket: a channel process can only join a
      # given topic once per socket.
      results =
        for _ <- 1..3 do
          {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: "any-token"})

          subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{
            "after" => 0
          })
        end

      assert Enum.all?(results, &match?({:ok, _reply, _socket}, &1))
    end
  end

  # Every token authenticates as the SAME configured test subject, regardless
  # of the token's actual value — lets the rate-limiting tests above drive
  # every join as one consistent subject without needing a real JWT.
  defmodule FixedSubjectVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify(_token) do
      {:ok, %{"sub" => Application.fetch_env!(:riptide, :ratelimit_test_subject)}}
    end
  end
end
