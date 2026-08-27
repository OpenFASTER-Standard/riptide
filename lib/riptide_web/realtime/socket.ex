defmodule RiptideWeb.Realtime.Socket do
  @moduledoc """
  Phoenix Socket for StreamLD's WebSocket replication transport — mounts
  `ReplicationChannel` on the `replication:*` topic.

  Authentication is optional (Phase 4b): a connection with no `auth_token`
  proceeds with `socket.assigns.current_subject` set to `nil`; a connection
  presenting a token that fails verification is refused outright. The token
  itself arrives via Phoenix's `auth_token: true` socket option (see
  `RiptideWeb.Endpoint`), which reads it from the `Sec-WebSocket-Protocol`
  header rather than a raw `Authorization` header — Phoenix does not expose
  arbitrary request headers to `connect/3` at all, for cross-origin
  handshake safety. Verification happens once, here, at connect time; a
  channel `join/3` never re-verifies — the socket-level identity already
  applies to every channel joined on it. Assigns no socket id, since there's
  no per-connection session distinguishing one reader from another.
  """
  use Phoenix.Socket
  require Logger

  channel "replication:*", RiptideWeb.Realtime.ReplicationChannel

  @impl true
  def connect(_params, socket, connect_info) do
    case Map.get(connect_info, :auth_token) do
      nil ->
        {:ok, assign(socket, :current_subject, nil)}

      token ->
        verifier = Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)

        case verifier.verify(token) do
          {:ok, claims} ->
            if sub = claims["sub"] do
              Logger.metadata(subject: sub)
            end

            {:ok, assign(socket, :current_subject, claims)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def id(_socket), do: nil
end
