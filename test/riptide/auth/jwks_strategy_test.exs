defmodule Riptide.Auth.JwksStrategyTest do
  use ExUnit.Case, async: false

  alias Riptide.Auth.JwksStrategy

  setup do
    original = Application.get_env(:riptide, :oidc_jwks_url)
    on_exit(fn -> Application.put_env(:riptide, :oidc_jwks_url, original) end)
    :ok
  end

  test "init_opts/1 defaults jwks_url from Application config when not already set" do
    Application.put_env(:riptide, :oidc_jwks_url, "https://issuer.example/jwks")

    assert JwksStrategy.init_opts([])[:jwks_url] == "https://issuer.example/jwks"
  end

  test "init_opts/1 does not override an explicitly-passed jwks_url" do
    Application.put_env(:riptide, :oidc_jwks_url, "https://issuer.example/jwks")

    assert JwksStrategy.init_opts(jwks_url: "https://explicit.example/jwks")[:jwks_url] ==
             "https://explicit.example/jwks"
  end
end
