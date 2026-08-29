defmodule Riptide.Derivation.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Riptide.Capability.Definition
  alias Riptide.Derivation.ExecuteInterpreter
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{AntiUnifier, Catalog, DedupGate, Discovery, LLMFallback}
  alias Riptide.Derivation.{Rule, Signature, Var}

  defp unique_tenant, do: {:tenant, "acme-#{System.unique_integer([:positive])}"}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)
  defp cap(name), do: RDF.iri("urn:riptide:capability:" <> name)

  # free_var_count: 0, 1, or 2 — controls how many of the Head's two
  # FactPattern args are free `Var`s (a FactPattern always has exactly 2
  # args, subject + object), giving each test control over specificity
  # without needing a real Body.
  defp sample_rule(predicate_local_name, free_var_count) do
    predicate = rel(predicate_local_name)

    head_args =
      case free_var_count do
        0 -> [t("subject"), RDF.literal("object")]
        1 -> [%Var{name: "X"}, RDF.literal("object")]
        2 -> [%Var{name: "X"}, %Var{name: "Y"}]
      end

    head = %FactPattern{predicate: predicate, args: head_args}

    %Rule{
      signature: %Signature{
        name: predicate,
        parameters: Enum.filter(head_args, &match?(%Var{}, &1)),
        reads: [],
        produces: [predicate]
      },
      head: head,
      body: []
    }
  end

  describe "find/2 — exact match" do
    test "a query whose words exactly match a found entry's predicate is ranked" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      rule = sample_rule("pendingDeploy", 0)
      :ok = Catalog.admit_entry(scope, rule, nil)

      assert {:ok, [{_node, ^rule}]} = Discovery.find(scope, "pending deploy")
    end
  end

  describe "find/2 — keyword match" do
    test "a query with partial word overlap, no exact candidate, is found via keyword fallback" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      rule = sample_rule("pendingDeploy", 0)
      :ok = Catalog.admit_entry(scope, rule, nil)

      assert {:ok, [{_node, ^rule}]} = Discovery.find(scope, "deploy the service")
    end
  end

  describe "find/2 — no match" do
    test "a query with zero word overlap returns {:ok, []}, not an error" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      rule = sample_rule("pendingDeploy", 0)
      :ok = Catalog.admit_entry(scope, rule, nil)

      assert Discovery.find(scope, "unrelated task") == {:ok, []}
    end
  end

  describe "find/2 — specificity tiebreak" do
    test "within the same tier, fewer free variables ranks first" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      specific_rule = sample_rule("greeted", 0)
      general_rule = sample_rule("greeted", 1)

      :ok = Catalog.admit_entry(scope, general_rule, nil)
      :ok = Catalog.admit_entry(scope, specific_rule, nil)

      assert {:ok, [{_node1, ^specific_rule}, {_node2, ^general_rule}]} =
               Discovery.find(scope, "greeted")
    end
  end

  describe "find/2 — exact outranks a higher-overlap keyword hit" do
    test "tier is the primary sort key, not raw overlap count" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      exact_rule = sample_rule("pendingDeploy", 0)
      keyword_rule = sample_rule("pendingDeployNow", 0)

      :ok = Catalog.admit_entry(scope, keyword_rule, nil)
      :ok = Catalog.admit_entry(scope, exact_rule, nil)

      assert {:ok, [{_node1, ^exact_rule}, {_node2, ^keyword_rule}]} =
               Discovery.find(scope, "pending deploy")
    end
  end

  describe "find/2 — empty Catalog" do
    test "a Tenant scope with no CatalogEntry admitted yet returns {:ok, []}" do
      assert Discovery.find(unique_tenant(), "anything") == {:ok, []}
    end
  end

  defp context(overrides) do
    Map.merge(
      %Context{capabilities: %{}, rules: %{}, tenant_id: "acme", current_subject: nil},
      overrides
    )
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

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies(_tenant_id, _path_prefix) do
      [%Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}]
    end

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok

    @impl true
    def claim_tenant_if_unclaimed(_tenant_id, _subject), do: :already_claimed
  end

  defmodule FakeClient do
    @behaviour Riptide.Derivation.LLMFallback.Client

    @impl true
    def complete(_prompt), do: Agent.get(__MODULE__, & &1)

    def start(result) do
      case Agent.start_link(fn -> result end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> Agent.update(pid, fn _ -> result end); pid
      end
    end
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)

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

  describe "exit criterion (issue #68) — the full walking skeleton, third occurrence" do
    test "a CatalogEntry admitted by DedupGate is found by Discovery and invoked without an LLM call" do
      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope))
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      ctx = context(%{capabilities: %{cap("greetPerson") => greet_definition("greetPerson")}})

      graph =
        RDF.Graph.new([
          {t("alice"), rel("pendingDeploy"), RDF.literal("v1")},
          {t("alice"), rel("hasName"), RDF.literal("Alice")},
          {t("bob"), rel("pendingDeploy"), RDF.literal("v1")},
          {t("bob"), rel("hasName"), RDF.literal("Bob")}
        ])

      response1 =
        "greet(<urn:test:alice>, Result) :- pendingDeploy(<urn:test:alice>, Target), hasName(<urn:test:alice>, Name), capability(greetPerson, Name, Result)."

      response2 =
        "greet(<urn:test:bob>, Result) :- pendingDeploy(<urn:test:bob>, Target), hasName(<urn:test:bob>, Name), capability(greetPerson, Name, Result)."

      FakeClient.start({:ok, response1})
      Riptide.AppEnvTestHelpers.put_env(:riptide, :llm_fallback_client, FakeClient)
      assert {:ok, trace1} = LLMFallback.run("greet Alice", graph, ctx)

      FakeClient.start({:ok, response2})
      assert {:ok, trace2} = LLMFallback.run("greet Bob", graph, ctx)

      assert {:ok, candidates} = AntiUnifier.generalize(trace1, trace2)
      assert {:ok, [{:queued, node, :admit}]} = DedupGate.propose(scope, candidates, graph, ctx)
      assert :ok == DedupGate.approve_review(scope, node)

      # Third occurrence: found via Discovery's keyword path ("greet" is not
      # among the found entry's own predicate words — pending/deploy/has/name
      # — so this is genuinely a keyword match, not exact), then invoked
      # directly — no LLMFallback.run/3 call anywhere below this line.
      assert {:ok, [{_found_node, found_rule}]} = Discovery.find(scope, "greet Carol")

      [subject_var | _] = found_rule.signature.parameters

      carol_graph =
        RDF.Graph.new([
          {t("carol"), rel("pendingDeploy"), RDF.literal("v1")},
          {t("carol"), rel("hasName"), RDF.literal("Carol")}
        ])

      seed = %{subject_var => t("carol")}

      assert ExecuteInterpreter.call_template(found_rule, seed, carol_graph, ctx) ==
               {:ok, [{t("carol"), rel("greet"), "\"Hello, Carol!\""}]}
    end
  end
end
