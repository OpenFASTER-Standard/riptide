defmodule Riptide.Stream.StreamSupervisor do
  @moduledoc """
  Entry point for "make sure this stream's real, placement-driven Ra
  cluster is resolved and ready" — used by every request path (LDP HTTP,
  SSE, WebSocket replication). Calls `Riptide.Stream.Placement.
  ensure_started/2` directly rather than through `StreamServer.start_link/1`,
  since a stream's actual replicas may not include this node (Phase 3c-iii
  design spec §3) — `start_link/1`'s own "return a local pid" contract only
  ever made sense when this node was always assumed to be a replica.
  """

  alias Riptide.Stream.{Placement, RaMachine}

  @spec ensure_ready(String.t()) :: :ok | {:error, term()}
  def ensure_ready(stream_id) do
    case Placement.ensure_started(stream_id, {:module, RaMachine, %{retention: :infinity}}) do
      {:ok, _server_ids} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Normalizes ensure_ready/1's result for callers (every LDP/SSE/WebSocket
  # entry point) that only branch on success vs. failure, not the specific
  # error reason.
  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error
end
