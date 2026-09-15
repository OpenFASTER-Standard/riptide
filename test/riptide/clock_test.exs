defmodule Riptide.ClockTest do
  use ExUnit.Case, async: false

  defmodule FakeClock do
    @behaviour Riptide.Clock
    def now, do: 123_456
  end

  setup do
    previous = Application.get_env(:riptide, :clock)
    on_exit(fn -> Application.put_env(:riptide, :clock, previous) end)
    :ok
  end

  test "System.now/0 returns a real, current second-granularity timestamp" do
    before = System.system_time(:second)
    now = Riptide.Clock.System.now()
    afterward = System.system_time(:second)

    assert now >= before
    assert now <= afterward
  end

  test "Clock.now/0 defaults to Clock.System when unconfigured" do
    Application.delete_env(:riptide, :clock)
    assert Riptide.Clock.now() == Riptide.Clock.System.now()
  end

  test "Clock.now/0 delegates to whichever module is configured" do
    Application.put_env(:riptide, :clock, FakeClock)
    assert Riptide.Clock.now() == 123_456
  end
end
