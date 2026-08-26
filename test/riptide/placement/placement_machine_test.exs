defmodule Riptide.Placement.PlacementMachineTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement.PlacementMachine

  test "init/1 starts with empty streams and policies" do
    assert PlacementMachine.init(%{}) == %{streams: %{}, policies: %{}}
  end

  test "apply/3 stores a new stream's node list" do
    state = PlacementMachine.init(%{})

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    assert new_state == %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}}
    assert reply == [:a, :b, :c]
    assert effects == []
  end

  test "apply/3 is idempotent: a second proposal for an already-assigned stream returns the existing assignment" do
    state = PlacementMachine.init(%{})
    {state, _reply, _} = PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:assign, "s1", [:x, :y, :z]}, state)

    assert new_state == %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}}
    assert reply == [:a, :b, :c]
    assert effects == []
  end

  test "apply/3 stores two different streams independently" do
    state = PlacementMachine.init(%{})
    {state, _, _} = PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)
    {state, _, _} = PlacementMachine.apply(%{index: 2}, {:assign, "s2", [:d, :e, :f]}, state)

    assert state == %{streams: %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}, policies: %{}}
  end

  test "get/2 returns the assigned nodes for a known stream" do
    state = %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}}
    assert PlacementMachine.get(state, "s1") == [:a, :b, :c]
  end

  test "get/2 returns nil for an unknown stream" do
    assert PlacementMachine.get(%{streams: %{}, policies: %{}}, "unknown") == nil
  end

  test "list/1 returns only the stream_id => nodes map, not the internal policies state" do
    state = %{streams: %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}, policies: %{"acme" => %{}}}
    assert PlacementMachine.list(state) == %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}
  end

  test "list/1 returns an empty map when nothing is assigned yet" do
    assert PlacementMachine.list(PlacementMachine.init(%{})) == %{}
  end

  test "apply/3 {:replace_member, ...} swaps a dead node for a new one in an existing assignment" do
    state = %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "s1", :b, :z}, state)

    assert new_state == %{streams: %{"s1" => [:a, :z, :c]}, policies: %{}}
    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op if the named dead node is no longer present" do
    state = %{streams: %{"s1" => [:a, :z, :c]}, policies: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:replace_member, "s1", :b, :y}, state)

    assert new_state == %{streams: %{"s1" => [:a, :z, :c]}, policies: %{}}
    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op for an unknown stream_id" do
    state = %{streams: %{}, policies: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "unknown", :a, :b}, state)

    assert new_state == %{streams: %{}, policies: %{}}
    assert reply == nil
    assert effects == []
  end
end
