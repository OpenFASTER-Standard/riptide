defmodule Riptide.Stream.StreamSupervisor do
  @moduledoc """
  Entry point for "get me this stream's durable log, starting or restarting
  it from disk if needed." No longer a real OTP supervisor — `Ra` supervises
  its own server process; this just calls through to it.
  """

  alias Riptide.Stream.StreamServer

  @spec get_or_start(String.t()) :: pid()
  def get_or_start(stream_id) do
    {:ok, pid} = StreamServer.start_link({stream_id, []})
    pid
  end
end
