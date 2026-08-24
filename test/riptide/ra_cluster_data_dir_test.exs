defmodule Riptide.RaClusterDataDirTest do
  use ExUnit.Case, async: false

  alias Riptide.RaCluster

  test "data_dir/0 derives the directory name from HOSTNAME" do
    original = System.get_env("HOSTNAME")
    System.put_env("HOSTNAME", "riptide-2")

    try do
      assert Path.basename(RaCluster.data_dir()) == "riptide-2"
    after
      if original, do: System.put_env("HOSTNAME", original), else: System.delete_env("HOSTNAME")
    end
  end

  test "data_dir/0 falls back to \"nonode\" when HOSTNAME is unset" do
    original = System.get_env("HOSTNAME")
    System.delete_env("HOSTNAME")

    try do
      assert Path.basename(RaCluster.data_dir()) == "nonode"
    after
      if original, do: System.put_env("HOSTNAME", original)
    end
  end
end
