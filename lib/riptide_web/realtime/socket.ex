defmodule RiptideWeb.Realtime.Socket do
  @moduledoc """
  Phoenix Socket for StreamLD's WebSocket replication transport — mounts
  `ReplicationChannel` on the `replication:*` topic. Accepts every connection
  unconditionally (no socket-level auth yet) and assigns no socket id, since
  there's no per-connection session distinguishing one reader from another.
  """
  use Phoenix.Socket

  channel "replication:*", RiptideWeb.Realtime.ReplicationChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
