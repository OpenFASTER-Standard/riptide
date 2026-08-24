defmodule Riptide.ApplicationTest do
  use ExUnit.Case, async: true

  test "Riptide.ClusterSupervisor starts as part of the application" do
    assert Process.whereis(Riptide.ClusterSupervisor) |> is_pid()
  end
end
