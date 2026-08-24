defmodule Riptide.Test.EchoMachine do
  @moduledoc """
  A minimal `:ra_machine` test double: a list accumulator. `init/1` returns
  `[]`; `apply/3` handles `{:add, item}` by prepending it to the state.

  Lives in `test/support` (compiled for every test file, see `mix.exs`'s
  `elixirc_paths/1`) rather than nested inside a single test module, so any
  test file can reference it directly — nesting it inside one test module
  only works when that module happens to already be compiled/loaded in the
  same `mix test` invocation, which isn't true when running a single other
  test file in isolation (e.g. `mix test test/riptide/some_other_test.exs`).
  """

  @behaviour :ra_machine

  @impl :ra_machine
  def init(_config), do: []

  @impl :ra_machine
  def apply(_meta, {:add, item}, state) do
    new_state = [item | state]
    {new_state, new_state, []}
  end
end
