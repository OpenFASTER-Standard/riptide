defmodule Riptide.Tenancy.Resolver.SubdomainTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Riptide.Tenancy.Resolver.Subdomain

  test "resolves tenant_id from the leading subdomain label" do
    conn = %{conn(:get, "/resources/foo") | host: "acme.riptide.example"}

    assert Subdomain.resolve(conn) == {:ok, "acme"}
  end

  test "returns an error when the host has no tenant subdomain (bare base domain)" do
    conn = %{conn(:get, "/resources/foo") | host: "riptide.example"}

    assert {:error, _reason} = Subdomain.resolve(conn)
  end

  test "returns an error when the host is a bare single label" do
    conn = %{conn(:get, "/resources/foo") | host: "localhost"}

    assert {:error, _reason} = Subdomain.resolve(conn)
  end

  test "resolves correctly even with a multi-label base domain" do
    conn = %{conn(:get, "/resources/foo") | host: "acme.riptide.example.com"}

    assert Subdomain.resolve(conn) == {:ok, "acme"}
  end
end
