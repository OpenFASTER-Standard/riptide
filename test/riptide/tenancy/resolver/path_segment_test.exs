defmodule Riptide.Tenancy.Resolver.PathSegmentTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Riptide.Tenancy.Resolver.PathSegment

  test "resolves tenant_id from a conn whose route already bound a :tenant_id param" do
    conn = %{conn(:get, "/tenants/acme/resources/foo") | params: %{"tenant_id" => "acme"}}

    assert PathSegment.resolve(conn) == {:ok, "acme"}
  end

  test "returns an error when no tenant_id param is present" do
    conn = conn(:get, "/resources/foo")

    assert {:error, _reason} = PathSegment.resolve(conn)
  end

  test "returns an error when tenant_id is present but empty" do
    conn = %{conn(:get, "/tenants//resources/foo") | params: %{"tenant_id" => ""}}

    assert {:error, _reason} = PathSegment.resolve(conn)
  end
end
