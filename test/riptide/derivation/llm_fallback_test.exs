defmodule Riptide.Derivation.LLMFallbackTest do
  use ExUnit.Case, async: false

  alias Riptide.Capability.Definition
  alias Riptide.Derivation.{AntiUnifier, Catalog, DedupGate, LLMFallback}
  alias Riptide.Derivation.ExecuteInterpreter.Context

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)
  defp cap(name), do: RDF.iri("urn:riptide:capability:" <> name)

  defp context(overrides \\ %{}) do
    Map.merge(
      %Context{capabilities: %{}, rules: %{}, tenant_id: "acme", current_subject: nil},
      overrides
    )
  end

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies(tenant_id, path_prefix) do
      Agent.get(__MODULE__, &Map.get(&1, {tenant_id, path_prefix}, []))
    end

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok

    @impl true
    def claim_tenant_if_unclaimed(_tenant_id, _subject), do: :already_claimed

    def start(policies_by_prefix) do
      case Agent.start_link(fn -> policies_by_prefix end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)

    on_exit(fn ->
      if pid = Process.whereis(FakeStore) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp greet_definition(name) do
    %Definition{
      name: cap(name),
      kind: :effect,
      component: "test/fixtures/riptide_capability/fixture.wasm",
      function: "greet",
      fuel_limit: 100_000_000,
      timeout_ms: 5_000,
      memory_limits: %{
        max_memory_size: nil,
        max_table_elements: nil,
        max_instances: nil,
        max_tables: nil
      }
    }
  end

  defmodule FakeClient do
    @behaviour Riptide.Derivation.LLMFallback.Client

    @impl true
    def complete(prompt) do
      Agent.update(__MODULE__, &Map.put(&1, :last_prompt, prompt))
      Map.fetch!(Agent.get(__MODULE__, & &1), :result)
    end

    def start(result) do
      case Agent.start_link(fn -> %{result: result, last_prompt: nil} end, name: __MODULE__) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          Agent.update(pid, &%{&1 | result: result})
          pid
      end
    end

    def last_prompt, do: Agent.get(__MODULE__, & &1.last_prompt)
  end

  setup do
    on_exit(fn ->
      if pid = Process.whereis(FakeClient) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp with_fake_client(result, fun) do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :llm_fallback_client, FakeClient)
    FakeClient.start(result)
    fun.()
  end

  describe "run/3 — pass case" do
    test "an LLM-authored Rule, resolved via real Capability invocation, becomes a ground Trace" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetSomeone"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      response =
        "greeted(<urn:test:riptide>, Greeting) :- capability(greetSomeone, \"Alice\", Greeting)."

      ctx = context(%{capabilities: %{cap("greetSomeone") => greet_definition("greetSomeone")}})

      with_fake_client({:ok, response}, fn ->
        assert {:ok, trace} = LLMFallback.run("greet Alice", RDF.Graph.new(), ctx)

        assert trace.head == %Riptide.Derivation.Literal.FactPattern{
                 predicate: rel("greeted"),
                 args: [t("riptide"), "\"Hello, Alice!\""]
               }

        assert [%Riptide.Derivation.Literal.CapabilityReference{} = capability_reference] =
                 trace.body

        assert capability_reference.capability == cap("greetSomeone")
        assert capability_reference.args == [RDF.literal("Alice")]
        assert capability_reference.result == "\"Hello, Alice!\""
      end)
    end
  end

  describe "run/3 — prompt content" do
    test "the prompt lists the tenant's real capability names, not a hallucinated one" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetSomeone"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      response =
        "greeted(<urn:test:riptide>, Greeting) :- capability(greetSomeone, \"Alice\", Greeting)."

      ctx = context(%{capabilities: %{cap("greetSomeone") => greet_definition("greetSomeone")}})

      with_fake_client({:ok, response}, fn ->
        {:ok, _trace} = LLMFallback.run("greet Alice", RDF.Graph.new(), ctx)

        assert FakeClient.last_prompt() =~ "urn:riptide:capability:greetSomeone"
      end)
    end
  end

  describe "run/3 — unparseable response" do
    test "a response that isn't valid rule text is a real, surfaced error" do
      ctx = context()

      with_fake_client({:ok, "this is not a rule clause at all"}, fn ->
        assert {:error, {:unparseable_response, _reason}} =
                 LLMFallback.run("do something", RDF.Graph.new(), ctx)
      end)
    end
  end

  describe "run/3 — unresolvable capability reference" do
    test "a response naming a capability the tenant doesn't have registered is a real, surfaced error" do
      response =
        "greeted(<urn:test:riptide>, Greeting) :- capability(notRegistered, \"Alice\", Greeting)."

      ctx = context()

      with_fake_client({:ok, response}, fn ->
        assert {:error, {:unresolvable, iri}} =
                 LLMFallback.run("greet Alice", RDF.Graph.new(), ctx)

        assert iri == cap("notRegistered")
      end)
    end
  end

  describe "run/3 — no match" do
    test "a response whose Body matches nothing in the graph is :no_match" do
      response =
        "greeted(<urn:test:riptide>, Result) :- pendingDeploy(<urn:test:riptide>, Result)."

      ctx = context()

      with_fake_client({:ok, response}, fn ->
        assert LLMFallback.run("greet Alice", RDF.Graph.new(), ctx) == {:error, :no_match}
      end)
    end
  end

  describe "run/3 — ambiguous match" do
    test "a response whose Body matches more than one way is :ambiguous_match" do
      response =
        "greeted(<urn:test:riptide>, Target) :- pendingDeploy(<urn:test:riptide>, Target)."

      graph =
        RDF.Graph.new([
          {t("riptide"), rel("pendingDeploy"), t("v1")},
          {t("riptide"), rel("pendingDeploy"), t("v2")}
        ])

      ctx = context()

      with_fake_client({:ok, response}, fn ->
        assert LLMFallback.run("deploy riptide", graph, ctx) == {:error, :ambiguous_match}
      end)
    end
  end

  describe "run/3 — LLM call failure" do
    test "a failing Client.complete/1 call surfaces as {:llm_error, reason}" do
      ctx = context()

      with_fake_client({:error, :timeout}, fn ->
        assert LLMFallback.run("greet Alice", RDF.Graph.new(), ctx) ==
                 {:error, {:llm_error, :timeout}}
      end)
    end
  end

  describe "exit criterion (issue #67) — the full walking skeleton" do
    test "a Task with no Catalog match, run through LLMFallback twice, anti-unifies, passes DedupGate's Admit path, and becomes a live CatalogEntry" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetPerson"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      scope = {:tenant, "acme-#{System.unique_integer([:positive])}"}

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope))
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      ctx = context(%{capabilities: %{cap("greetPerson") => greet_definition("greetPerson")}})

      graph =
        RDF.Graph.new([
          {t("alice"), rel("pendingDeploy"), RDF.literal("v1")},
          {t("bob"), rel("pendingDeploy"), RDF.literal("v1")}
        ])

      response1 =
        "greeted(<urn:test:alice>, Result) :- pendingDeploy(<urn:test:alice>, Target), capability(greetPerson, \"Alice\", Result)."

      response2 =
        "greeted(<urn:test:bob>, Result) :- pendingDeploy(<urn:test:bob>, Target), capability(greetPerson, \"Bob\", Result)."

      trace1 =
        with_fake_client({:ok, response1}, fn ->
          assert {:ok, trace1} = LLMFallback.run("greet Alice", graph, ctx)
          trace1
        end)

      trace2 =
        with_fake_client({:ok, response2}, fn ->
          assert {:ok, trace2} = LLMFallback.run("greet Bob", graph, ctx)
          trace2
        end)

      assert {:ok, candidates} = AntiUnifier.generalize(trace1, trace2)

      assert {:ok, [{:queued, node, :admit}]} = DedupGate.propose(scope, candidates, graph, ctx)

      assert :ok == DedupGate.approve_review(scope, node)

      assert {:ok, [{_entry_node, _rule}]} = Catalog.list_entries(scope)
    end
  end
end
