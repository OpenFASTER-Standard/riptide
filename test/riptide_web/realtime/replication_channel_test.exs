defmodule RiptideWeb.Realtime.ReplicationChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  alias Riptide.Event
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.Realtime.{ReplicationChannel, Socket}

  @endpoint RiptideWeb.Endpoint

  defp unique_stream_id, do: "ws-test-#{System.unique_integer([:positive])}"

  test "joining with after: 0 receives no backlog on an empty stream" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.get_or_start(stream_id)

    {:ok, socket} = connect(Socket, %{})

    {:ok, reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    assert reply == %{"backlog" => []}
  end

  test "joining with after: 0 on a non-empty stream replies with the existing backlog" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.get_or_start(stream_id)
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
    StreamSupervisor.get_or_start(stream_id)

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
end
