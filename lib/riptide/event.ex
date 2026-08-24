defmodule Riptide.Event do
  @moduledoc """
  Mirrors the StreamLD EventEnvelope SHACL shape
  (spec/streamld/model/envelope.ttl) on the wire, but internally carries an
  explicit operation instead of the wire's single `isSnapshot` boolean —
  `:patch` events store a real `Riptide.RDF.Patch` (additions AND removals),
  not just a merged graph, so replaying the log can actually apply a
  removal. See `wire_snapshot?/1`/`wire_payload/1` for how this maps back
  down to the wire's `isSnapshot`/`payload` fields unchanged.
  """

  alias Riptide.RDF.Patch

  @enforce_keys [:stream_id, :operation, :payload]
  defstruct [:sequence, :stream_id, :operation, :payload]

  @type operation :: :replace | :delete | :patch
  @type payload :: RDF.Graph.t() | Patch.t()
  @type t :: %__MODULE__{
          sequence: pos_integer() | nil,
          stream_id: String.t(),
          operation: operation(),
          payload: payload()
        }

  @spec new(String.t(), :replace, RDF.Graph.t()) :: t()
  @spec new(String.t(), :delete, RDF.Graph.t()) :: t()
  @spec new(String.t(), :patch, Patch.t()) :: t()
  def new(stream_id, :replace, %RDF.Graph{} = payload) do
    %__MODULE__{stream_id: stream_id, operation: :replace, payload: payload}
  end

  def new(stream_id, :delete, %RDF.Graph{} = payload) do
    %__MODULE__{stream_id: stream_id, operation: :delete, payload: payload}
  end

  def new(stream_id, :patch, %Patch{} = payload) do
    %__MODULE__{stream_id: stream_id, operation: :patch, payload: payload}
  end

  @spec with_sequence(t(), pos_integer()) :: t()
  def with_sequence(%__MODULE__{} = event, sequence)
      when is_integer(sequence) and sequence > 0 do
    %{event | sequence: sequence}
  end

  @spec wire_snapshot?(t()) :: boolean()
  def wire_snapshot?(%__MODULE__{operation: :replace}), do: true
  def wire_snapshot?(%__MODULE__{operation: :delete}), do: true
  def wire_snapshot?(%__MODULE__{operation: :patch}), do: false

  @spec wire_payload(t()) :: RDF.Graph.t()
  def wire_payload(%__MODULE__{operation: :replace, payload: graph}), do: graph
  def wire_payload(%__MODULE__{operation: :delete, payload: graph}), do: graph

  # The StreamLD wire protocol has no removals field today (out of scope —
  # see the design doc's Global Constraints); a :patch's wire payload is
  # additions-only, same net wire behavior as before this task.
  def wire_payload(%__MODULE__{operation: :patch, payload: %Patch{additions: additions}}) do
    RDF.Graph.new() |> RDF.Graph.add(additions)
  end
end
