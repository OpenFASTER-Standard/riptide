defmodule RiptideWeb.Realtime.ReplicationChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.Realtime.{ReplicationChannel, Socket}

  @endpoint RiptideWeb.Endpoint

  defp unique_stream_id, do: "ws-test-#{System.unique_integer([:positive])}"

  test "joining with after: 0 receives no backlog on an empty stream" do
    stream_id = unique_stream_id()
    StreamSupervisor.get_or_start(stream_id)

    {:ok, socket} = connect(Socket, %{})

    {:ok, reply, _socket} = subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    assert reply == %{"backlog" => []}
  end

  test "joining with after: 0 on a non-empty stream replies with the existing backlog" do
    stream_id = unique_stream_id()
    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    {:ok, socket} = connect(Socket, %{})
    {:ok, reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    assert %{"backlog" => [%{"cursor" => 1}]} = reply
  end

  test "joining with a cursor older than the retention window is rejected with a gap" do
    stream_id = unique_stream_id()
    {:ok, _pid} = StreamServer.start_link({stream_id, retention: 1})
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    {:ok, socket} = connect(Socket, %{})

    assert {:error, %{"gap" => 2}} =
             subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})
  end

  test "new appends after joining are pushed as replication_frame messages" do
    stream_id = unique_stream_id()
    StreamSupervisor.get_or_start(stream_id)

    {:ok, socket} = connect(Socket, %{})
    {:ok, _reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    assert_push "replication_frame", %{"cursor" => 1}
  end
end
