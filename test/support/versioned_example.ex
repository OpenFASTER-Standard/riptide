defmodule Riptide.Test.VersionedExample do
  @moduledoc """
  A minimal, throwaway two-version encode/decode chain. Exists only to prove
  the upcast-then-recurse `decode/1` pattern described in the Phase 3a design
  spec (§5) works mechanically — `Riptide.Event`/`Riptide.RDF.Patch` only have
  one real version today and can't demonstrate an actual version bump yet.
  Not used by any production code.
  """

  defstruct [:name, :count]

  @type t :: %__MODULE__{name: String.t(), count: non_neg_integer()}

  @spec decode(map()) :: t()
  def decode(%{v: 2, name: name, count: count}) do
    %__MODULE__{name: name, count: count}
  end

  def decode(%{v: 1} = wire) do
    wire |> upcast_v1_to_v2() |> decode()
  end

  # v1 had no `count` field; v2 added it, defaulting absent counts to 0.
  defp upcast_v1_to_v2(%{v: 1, name: name}) do
    %{v: 2, name: name, count: 0}
  end
end
