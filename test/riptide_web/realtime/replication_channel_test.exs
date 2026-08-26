defmodule RiptideWeb.Realtime.ReplicationChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  alias Riptide.Event
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
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

  defp unique_stream_id, do: "ws-test-#{System.unique_integer([:positive])}"

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
    stream_a = "stream-a-" <> Uniq.UUID.uuid4()
    stream_b = "stream-b-" <> Uniq.UUID.uuid4()
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

  test "ensure_ready_status/1 maps :ok and {:error, _} correctly" do
    assert ReplicationChannel.ensure_ready_status(:ok) == :ok
    assert ReplicationChannel.ensure_ready_status({:error, :cluster_not_formed}) == :error
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
end
