defmodule Riptide.Authz.PolicyRDFCodecTest do
  use ExUnit.Case, async: true

  alias Riptide.Authz.Policy
  alias Riptide.Authz.PolicyRDFCodec

  test "round-trips an :agent-matched policy through RDF" do
    policy = %Policy{effect: :allow, modes: [:read, :write], matcher: {:agent, "sub-123"}}
    {node, graph} = PolicyRDFCodec.to_rdf(policy, [])

    assert PolicyRDFCodec.from_rdf(node, graph) == {[], policy}
  end

  test "round-trips a :public policy with a non-empty path_prefix" do
    policy = %Policy{effect: :allow, modes: [:read], matcher: :public}
    {node, graph} = PolicyRDFCodec.to_rdf(policy, ["docs", "sub"])

    assert PolicyRDFCodec.from_rdf(node, graph) == {["docs", "sub"], policy}
  end

  test "round-trips an :authenticated, :deny policy" do
    policy = %Policy{effect: :deny, modes: [:write], matcher: :authenticated}
    {node, graph} = PolicyRDFCodec.to_rdf(policy, [])

    assert PolicyRDFCodec.from_rdf(node, graph) == {[], policy}
  end
end
