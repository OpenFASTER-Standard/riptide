defmodule Riptide.Clock.VirtualTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _pid} = start_supervised({Riptide.Clock.Virtual, 1_000})
    :ok
  end

  test "now/0 returns the seeded initial value" do
    assert Riptide.Clock.Virtual.now() == 1_000
  end

  test "advance/1 moves the clock forward without any real waiting" do
    Riptide.Clock.Virtual.advance(86_400 * 365 * 10)
    assert Riptide.Clock.Virtual.now() == 1_000 + 86_400 * 365 * 10
  end

  test "advance/1 is cumulative across multiple calls" do
    Riptide.Clock.Virtual.advance(100)
    Riptide.Clock.Virtual.advance(200)
    assert Riptide.Clock.Virtual.now() == 1_300
  end
end
