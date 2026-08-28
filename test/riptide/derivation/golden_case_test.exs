defmodule Riptide.Derivation.GoldenCaseTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.{Parser, RuleRDFCodec}
  alias Riptide.Event
  alias Riptide.Stream.StreamServer

  @golden_cases %{
    "fact-pattern-only" => "deployed(Svc, Result) :- pendingDeploy(Svc, Result).",
    "capability-reference" =>
      "deployed(Svc, Outcome) :- pendingDeploy(Svc, Target), capability(deployService, Svc, Target, Outcome).",
    "rule-reference" =>
      "notified(Svc, Result) :- capability(deployService, Svc, Svc, Outcome), rule(notifyTeam, Svc, Outcome, Result).",
    "all three literal kinds" => """
    deployed(Svc, Result) :-
        pendingDeploy(Svc, Target),
        capability(deployService, Svc, Target, Outcome),
        rule(notifyTeam, Svc, Outcome, Result).
    """,
    "recursive" => "path(X, Y) :- edge(X, Y)."
  }

  for {name, text} <- @golden_cases do
    @tag text: text
    test "round-trips through the real EDB: #{name}", %{text: text} do
      stream_id = "derivation-golden-case-#{System.unique_integer([:positive])}"
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
      {:ok, _pid} = StreamServer.start_link(stream_id)

      {:ok, original_rule} = Parser.decode(text)
      {node, graph} = RuleRDFCodec.to_rdf(original_rule)

      StreamServer.append(stream_id, Event.new(stream_id, :replace, graph))

      # `get_since/2` with a `nil` cursor is deliberate live-tail semantics
      # (see `Riptide.Stream.RaMachine.get_since/2`) — it always returns `{:ok,
      # []}` regardless of what's been appended, so it can't be used to read
      # back history. `0` is the "since the beginning" cursor used elsewhere
      # for full-history reads (e.g. `Riptide.LDP.ResourceController`).
      {:ok, [persisted_event]} = StreamServer.get_since(stream_id, 0)
      decoded_rule = RuleRDFCodec.from_rdf(node, persisted_event.payload)

      assert decoded_rule == original_rule
    end
  end
end
