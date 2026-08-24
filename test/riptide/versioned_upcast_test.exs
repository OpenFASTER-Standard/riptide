defmodule Riptide.VersionedUpcastTest do
  use ExUnit.Case, async: true

  alias Riptide.Test.VersionedExample

  test "decode/1 upcasts an old-version map through to the current shape" do
    old_wire = %{v: 1, name: "alice"}

    assert VersionedExample.decode(old_wire) == %VersionedExample{name: "alice", count: 0}
  end

  test "decode/1 decodes the current version directly, without upcasting" do
    current_wire = %{v: 2, name: "bob", count: 5}

    assert VersionedExample.decode(current_wire) == %VersionedExample{name: "bob", count: 5}
  end
end
