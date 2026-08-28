defmodule Riptide.MultiNodeTestHelpers do
  @moduledoc """
  Shared helper for `:peer`-based multi-node test files — `unique_pairs/1`
  was duplicated byte-for-byte across 10 of them (verified via md5sum
  before extracting). Only ever called from the test process itself (to
  compute which node pairs to `:net_kernel.connect_node/1` between), never
  pushed to or executed on a spawned `:peer` node, so no peer-side
  compilation concerns apply here.
  """

  @spec unique_pairs([node()]) :: [{node(), node()}]
  def unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end
end
