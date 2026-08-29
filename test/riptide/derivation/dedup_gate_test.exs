defmodule Riptide.Derivation.DedupGateTest do
  use ExUnit.Case, async: false

  alias Riptide.Capability.Definition
  alias Riptide.Derivation.{AntiUnifier, Catalog, DedupGate, Rule, Signature}
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  defp unique_tenant, do: {:tenant, "acme-#{System.unique_integer([:positive])}"}

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
      name: RDF.iri("urn:riptide:capability:" <> name),
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

  defp ground_greet_trace(subject_name, arg_name) do
    cap_iri = RDF.iri("urn:riptide:capability:greetPerson")
    result = "\"Hello, #{arg_name}!\""

    %Rule{
      signature: %Signature{
        name: rel("greeted"),
        parameters: [t(subject_name), result],
        reads: [rel("pendingDeploy")],
        produces: [rel("greeted")]
      },
      head: %FactPattern{predicate: rel("greeted"), args: [t(subject_name), result]},
      body: [
        %FactPattern{predicate: rel("pendingDeploy"), args: [t(subject_name), RDF.literal("v1")]},
        %CapabilityReference{capability: cap_iri, args: [RDF.literal(arg_name)], result: result}
      ]
    }
  end

  describe "propose/4 — Admit path on an empty Catalog" do
    test "a novel candidate against an empty Catalog is queued as :admit with passing fidelity evidence" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetPerson"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope))
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      trace1 = ground_greet_trace("alice", "Alice")
      trace2 = ground_greet_trace("bob", "Bob")

      assert {:ok, candidates} = AntiUnifier.generalize(trace1, trace2)

      graph =
        RDF.Graph.new([
          {t("alice"), rel("pendingDeploy"), RDF.literal("v1")},
          {t("bob"), rel("pendingDeploy"), RDF.literal("v1")}
        ])

      ctx =
        context(%{
          capabilities: %{
            RDF.iri("urn:riptide:capability:greetPerson") => greet_definition("greetPerson")
          }
        })

      assert {:ok, [{:queued, node, :admit}]} = DedupGate.propose(scope, candidates, graph, ctx)
      assert {:ok, [{^node, _pending_review}]} = Catalog.list_pending_reviews(scope)
    end
  end

  describe "propose/4 — Reject/Merge classification against a non-empty Catalog" do
    test "a candidate already covered by an existing entry is Rejected, no review queued" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      # The existing entry is already the exact lgg of trace1/trace2 below —
      # anti-unifying the same candidate against it a second time must find
      # nothing new (entry_unchanged?).
      trace1 = ground_greet_trace("alice", "Alice")
      trace2 = ground_greet_trace("bob", "Bob")
      {:ok, [{existing_entry, _sub1, _sub2}]} = AntiUnifier.generalize(trace1, trace2)
      :ok = Catalog.admit_entry(scope, existing_entry, nil)

      trace3 = ground_greet_trace("carol", "Carol")
      {:ok, candidates} = AntiUnifier.generalize(trace1, trace3)

      graph = RDF.Graph.new()
      ctx = context()

      assert {:ok, [{:rejected, _reason}]} = DedupGate.propose(scope, candidates, graph, ctx)
      assert {:ok, []} = Catalog.list_pending_reviews(scope)
    end

    test "a candidate broader than an existing entry is queued as :merge, replaces the existing node" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetPerson"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope))
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      # A narrower existing entry: a single ground fact, no variables at all
      # (trivially still a valid Rule — an empty Body, a ground Head).
      # A proper RDF.Literal (not a raw Elixir string) — a raw string is what
      # a real CapabilityReference.result value looks like (a known,
      # documented 6d-i/6e-ii quirk), but raw strings get coerced into
      # RDF.Literal by real RDF.Graph storage on write, so a hand-built
      # fixture asserting round-trip equality needs to already be in the
      # form real storage will hand back.
      existing_entry = %Rule{
        signature: %Signature{
          name: rel("greeted"),
          parameters: [t("alice"), RDF.literal("Hello, Alice!")],
          reads: [],
          produces: [rel("greeted")]
        },
        head: %FactPattern{
          predicate: rel("greeted"),
          args: [t("alice"), RDF.literal("Hello, Alice!")]
        },
        body: []
      }

      :ok = Catalog.admit_entry(scope, existing_entry, nil)
      {:ok, [{existing_node, ^existing_entry}]} = Catalog.list_entries(scope)

      trace1 = ground_greet_trace("alice", "Alice")
      trace2 = ground_greet_trace("bob", "Bob")
      {:ok, candidates} = AntiUnifier.generalize(trace1, trace2)

      graph =
        RDF.Graph.new([
          {t("alice"), rel("pendingDeploy"), RDF.literal("v1")},
          {t("bob"), rel("pendingDeploy"), RDF.literal("v1")}
        ])

      ctx =
        context(%{
          capabilities: %{
            RDF.iri("urn:riptide:capability:greetPerson") => greet_definition("greetPerson")
          }
        })

      assert {:ok, [{:queued, node, :merge}]} = DedupGate.propose(scope, candidates, graph, ctx)
      assert {:ok, [{^node, pending_review}]} = Catalog.list_pending_reviews(scope)
      assert pending_review.replaces == existing_node
    end
  end
end
