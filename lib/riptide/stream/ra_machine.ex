defmodule Riptide.Stream.RaMachine do
  @moduledoc """
  The `:ra_machine` for a single stream's durable event log. Pure and
  process-free by design — `init/1`/`apply/3` are the only functions Ra
  itself calls; `get_since/2` is a plain query function run via
  `Riptide.RaCluster.local_query/2`, never a Ra command (reads don't need
  to go through consensus).
  """
  @behaviour :ra_machine

  alias Riptide.Event

  # `events` holds each event's *encoded* wire-form map (see `Riptide.Event.encode/1`),
  # not a raw `%Event{}` struct — this is what actually gets persisted (both in Ra's
  # command log and in machine-state snapshots), so it must stay in the versioned
  # format regardless of whether this stream's Ra cluster ever triggers a snapshot.
  # See Phase 3a design spec, §4.
  @type state :: %{
          next_sequence: pos_integer(),
          events: [map()],
          retention: :infinity | pos_integer()
        }

  @impl :ra_machine
  def init(%{retention: retention}) do
    %{next_sequence: 1, events: [], retention: retention}
  end

  @impl :ra_machine
  def apply(meta, {:append, wire}, state) do
    event = Event.decode(wire)
    stamped = Event.with_sequence(event, state.next_sequence)
    stamped_wire = Event.encode(stamped)
    {events, trimmed?} = trim(state.events ++ [stamped_wire], state.retention)
    new_state = %{state | next_sequence: state.next_sequence + 1, events: events}
    {new_state, stamped, release_cursor_effects(trimmed?, meta, new_state)}
  end

  # Ra keeps every applied command on disk in its raft log indefinitely
  # unless the machine tells it a prefix is no longer needed. `trim/2` only
  # bounds the *in-memory* `events` list — without this, the persisted
  # consensus log grows without bound for any stream with finite retention
  # (design doc §3.2). Whenever an append actually drops an event out of the
  # retention window, the machine state is fully self-contained (it carries
  # the trimmed `events` list and `next_sequence`), so it is safe to hand Ra a
  # snapshot of that state at this command's log index; Ra can then discard
  # every log entry at or before it and, on recovery, restore the snapshot and
  # replay only later entries.
  #
  # Effect-tuple shape is version-specific (verified against the pinned
  # `:ra` 2.15.4 — see `deps/ra/src/ra_server_proc.erl:1525`): the *3-tuple*
  # `{:release_cursor, Index, MachineState}` is the one that actually writes a
  # snapshot and truncates the log. The 2-tuple `{:release_cursor, Index}` in
  # this version only *promotes an existing checkpoint* and does NOT snapshot
  # on its own, so it would not bound the log here — do not "simplify" to it.
  #
  # Ra throttles the actual snapshotting (default `min_snapshot_interval` of
  # 4096 entries), so emitting this on every trimming append is cheap — most
  # are coalesced. Streams with `:infinity` retention never trim, so never
  # release a cursor: their log necessarily grows with their (deliberately
  # unbounded) state, which is inherent rather than a leak.
  defp release_cursor_effects(false, _meta, _state), do: []

  defp release_cursor_effects(true, %{index: index}, state),
    do: [{:release_cursor, index, state}]

  @spec get_since(state(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(_state, nil), do: {:ok, []}

  def get_since(state, cursor) do
    oldest = List.first(state.events) |> then(&(&1 && &1.sequence))

    if oldest != nil and cursor < oldest - 1 do
      {:gap, oldest}
    else
      {:ok, state.events |> Enum.filter(&(&1.sequence > cursor)) |> Enum.map(&Event.decode/1)}
    end
  end

  # Returns {trimmed_events, trimmed?} — the boolean drives whether `apply/3`
  # releases a Ra log cursor (see `release_cursor_effects/2`).
  defp trim(events, :infinity), do: {events, false}

  defp trim(events, retention) when is_integer(retention) do
    count = length(events)

    if count > retention do
      {Enum.drop(events, count - retention), true}
    else
      {events, false}
    end
  end
end
