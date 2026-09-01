defmodule Riptide.Accounts.RDFCodecTest do
  use ExUnit.Case, async: true

  alias Riptide.Accounts.{Account, RDFCodec}

  test "to_rdf/1 + from_rdf/2 round-trips an Account" do
    account = %Account{
      username: "alice",
      password_hash_sha256: String.duplicate("a", 64),
      sub: "11111111-1111-1111-1111-111111111111"
    }

    {node, graph} = RDFCodec.to_rdf(account)

    assert RDFCodec.from_rdf(node, graph) == account
  end
end
