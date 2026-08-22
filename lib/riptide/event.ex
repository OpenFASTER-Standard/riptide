defmodule Riptide.Event do
  @moduledoc """
  Mirrors the StreamLD EventEnvelope SHACL shape
  (spec/streamld/model/envelope.ttl): sequence, stream_id, is_snapshot?, payload.
  """

  @enforce_keys [:stream_id, :payload]
  defstruct [:sequence, :stream_id, :is_snapshot?, :payload]

  @type t :: %__MODULE__{
          sequence: pos_integer() | nil,
          stream_id: String.t(),
          is_snapshot?: boolean(),
          payload: RDF.Graph.t()
        }

  @spec new(String.t(), RDF.Graph.t(), boolean()) :: t()
  def new(stream_id, payload, is_snapshot? \\ false) do
    %__MODULE__{stream_id: stream_id, payload: payload, is_snapshot?: is_snapshot?}
  end

  @spec with_sequence(t(), pos_integer()) :: t()
  def with_sequence(%__MODULE__{} = event, sequence)
      when is_integer(sequence) and sequence > 0 do
    %{event | sequence: sequence}
  end
end
