defmodule Riptide.Derivation.DedupGateTest do
  use ExUnit.Case, async: false

  alias Riptide.Capability.Definition

  alias Riptide.Derivation.{
    AntiUnifier,
    Catalog,
    DedupGate,
    Provenance,
    Rule,
    RuleRDFCodec,
    Signature
  }

  alias Riptide.Derivation.DedupGate.PendingReview
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  defp unique_tenant, do: {:tenant, "acme-#{System.unique_integer([:positive])}"}

  # A ground CapabilityReference's `result` is a raw Elixir string by this
  # codebase's own established convention (matches `Capability.invoke/4`'s
  # real return type — see `generalization_fidelity_test.exs`'s identical
  # fixtures). RDF has no primitive distinct from Literal, so once such a
  # raw string is embedded (via Provenance) in a Rule admitted through the
  # RDF-backed Catalog, it comes back out as an `RDF.Literal`. Comparing a
  # post-admission entry against the exact pre-admission in-memory struct
  # therefore requires round-tripping the expectation through the same
  # codec Catalog itself uses, not comparing raw structs directly.
  defp rdf_round_trip(%Rule{} = rule) do
    {node, graph} = RuleRDFCodec.to_rdf(rule)
    RuleRDFCodec.from_rdf(node, graph)
  end

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

  defp sample_install_candidate do
    %Rule{
      signature: %Signature{
        name: rel("installed"),
        parameters: [],
        reads: [],
        produces: [rel("installed")]
      },
      head: %FactPattern{predicate: rel("installed"), args: [t("alice"), RDF.literal("hi")]},
      body: [],
      provenance: %Provenance{origin: {:installed_from, RDF.BlankNode.new("hub-entry"), []}}
    }
  end

  defp ground_greet_trace(subject_name, arg_name, predicate_local_name \\ "greeted") do
    cap_iri = RDF.iri("urn:riptide:capability:greetPerson")
    result = "\"Hello, #{arg_name}!\""
    predicate = rel(predicate_local_name)

    %Rule{
      signature: %Signature{
        name: predicate,
        parameters: [t(subject_name), result],
        reads: [rel("pendingDeploy")],
        produces: [predicate]
      },
      head: %FactPattern{predicate: predicate, args: [t(subject_name), result]},
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

      assert {:ok, [{:queued, node, :admit}]} =
               DedupGate.propose(scope, scope, candidates, graph, ctx)

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

      assert {:ok, [{:rejected, _reason}]} =
               DedupGate.propose(scope, scope, candidates, graph, ctx)

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

      assert {:ok, [{:queued, node, :merge}]} =
               DedupGate.propose(scope, scope, candidates, graph, ctx)

      assert {:ok, [{^node, pending_review}]} = Catalog.list_pending_reviews(scope)
      assert pending_review.replaces == existing_node
    end
  end

  describe "propose/4 — fidelity-failure path" do
    test "a candidate whose recorded Capability result doesn't match a fresh invocation never reaches pending-review" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetPerson"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      cap_iri = RDF.iri("urn:riptide:capability:greetPerson")

      # trace2's own recorded result is deliberately stale/wrong — a fresh
      # invocation of greet("Bob") always produces "Hello, Bob!", never this.
      stale_trace2 = %Rule{
        signature: %Signature{
          name: rel("greeted"),
          parameters: [t("bob"), "\"stale value\""],
          reads: [rel("pendingDeploy")],
          produces: [rel("greeted")]
        },
        head: %FactPattern{predicate: rel("greeted"), args: [t("bob"), "\"stale value\""]},
        body: [
          %FactPattern{predicate: rel("pendingDeploy"), args: [t("bob"), RDF.literal("v1")]},
          %CapabilityReference{
            capability: cap_iri,
            args: [RDF.literal("Bob")],
            result: "\"stale value\""
          }
        ]
      }

      trace1 = ground_greet_trace("alice", "Alice")
      {:ok, candidates} = AntiUnifier.generalize(trace1, stale_trace2)

      graph =
        RDF.Graph.new([
          {t("alice"), rel("pendingDeploy"), RDF.literal("v1")},
          {t("bob"), rel("pendingDeploy"), RDF.literal("v1")}
        ])

      ctx = context(%{capabilities: %{cap_iri => greet_definition("greetPerson")}})

      assert {:ok, [{:fidelity_failed, evidence}]} =
               DedupGate.propose(scope, scope, candidates, graph, ctx)

      assert :fidelity_pass in evidence
      assert Enum.any?(evidence, &match?({:fidelity_fail, _}, &1))
      assert {:ok, []} = Catalog.list_pending_reviews(scope)
    end
  end

  describe "propose/4 — multiple tied AntiUnifier candidates" do
    test "tied candidates are classified independently and land in different dispositions" do
      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope))
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      # Three same-predicate Body literals with ASYMMETRIC structure, ground
      # (real IRIs, not Vars — GeneralizationFidelity.check/3 requires
      # ground input, so trace1/trace2 here must already be real Traces).
      # Not 6e-i's own 2-literal swap test — that scenario's two tied
      # candidates turn out to be alpha-equivalent to each other, i.e. mere
      # renamings of each other (verified empirically); "tied on minimum
      # variable count" only means equally economical, not equivalent, and a
      # symmetric swap happens to produce isomorphic alignments. Here p1
      # recurs across body positions 1 and 3 in trace1 (asymmetric — p2
      # appears only once), and q1 recurs the same way in trace2, which
      # makes the two resulting alignments genuinely different in shape, not
      # just in variable naming — verified directly: with `candidate_a`/
      # `candidate_b` bound to the two candidates below,
      # `entry_unchanged?(candidate_a, candidate_a)` is (trivially) `true`,
      # but `entry_unchanged?(candidate_b, candidate_a)` is `false` —
      # candidate_b is NOT a mere renaming of candidate_a, it reveals genuine
      # broadening.
      trace1 = %Rule{
        signature: %Signature{
          name: rel("pair"),
          parameters: [t("p1"), t("p2")],
          reads: [rel("likes")],
          produces: [rel("pair")]
        },
        head: %FactPattern{predicate: rel("pair"), args: [t("p1"), t("p2")]},
        body: [
          %FactPattern{predicate: rel("likes"), args: [t("p1"), RDF.literal("a")]},
          %FactPattern{predicate: rel("likes"), args: [t("p2"), RDF.literal("b")]},
          %FactPattern{predicate: rel("likes"), args: [t("p1"), RDF.literal("c")]}
        ]
      }

      trace2 = %Rule{
        signature: %Signature{
          name: rel("pair"),
          parameters: [t("q1"), t("q2")],
          reads: [rel("likes")],
          produces: [rel("pair")]
        },
        head: %FactPattern{predicate: rel("pair"), args: [t("q1"), t("q2")]},
        body: [
          %FactPattern{predicate: rel("likes"), args: [t("q1"), RDF.literal("b")]},
          %FactPattern{predicate: rel("likes"), args: [t("q2"), RDF.literal("c")]},
          %FactPattern{predicate: rel("likes"), args: [t("q1"), RDF.literal("a")]}
        ]
      }

      {:ok, candidates} = AntiUnifier.generalize(trace1, trace2)
      assert length(candidates) == 2
      [{candidate_a, _, _}, {candidate_b, _, _}] = candidates

      # Seed the Catalog with candidate_a itself, verbatim — per the proof
      # above, candidate_b is NOT a mere renaming of candidate_a, so
      # re-proposing candidate_a is Reject (trivially unchanged) while
      # candidate_b reveals genuine broadening (Merge).
      :ok = Catalog.admit_entry(scope, candidate_a, nil)

      # All six ground facts trace1/trace2 depend on — candidate_b's own
      # reconstructed traces don't necessarily preserve trace1/trace2's
      # exact Body order (AntiUnifier.generalize/2 orders a candidate's Body
      # by its first input's own literal order, so a candidate built via a
      # "crossed" alignment can reconstruct a same-content-different-order
      # permutation of the second input — verified directly, harmless here
      # since FactPattern fidelity checking is a graph membership test, not
      # an order-sensitive one) — so the graph includes every fact either
      # trace needs, not just in whichever order each was originally written.
      graph =
        RDF.Graph.new([
          {t("p1"), rel("likes"), RDF.literal("a")},
          {t("p2"), rel("likes"), RDF.literal("b")},
          {t("p1"), rel("likes"), RDF.literal("c")},
          {t("q1"), rel("likes"), RDF.literal("b")},
          {t("q2"), rel("likes"), RDF.literal("c")},
          {t("q1"), rel("likes"), RDF.literal("a")}
        ])

      ctx = context()

      assert {:ok, outcomes} = DedupGate.propose(scope, scope, candidates, graph, ctx)

      assert [{:rejected, _reason}, {:queued, _node, :merge}] = outcomes
      refute candidate_a == candidate_b
    end
  end

  describe "approve_review/2 — :admit" do
    test "approving an :admit proposal writes a live CatalogEntry and resolves the pending item" do
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

      {:ok, [{:queued, node, :admit}]} = DedupGate.propose(scope, scope, candidates, graph, ctx)

      assert :ok == DedupGate.approve_review(scope, scope, node)
      assert {:ok, [{_entry_node, _rule}]} = Catalog.list_entries(scope)
      assert {:ok, []} = Catalog.list_pending_reviews(scope)
    end
  end

  describe "decline_review/2" do
    test "declining a proposal writes nothing to the Catalog and resolves the pending item" do
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

      {:ok, [{:queued, node, :admit}]} = DedupGate.propose(scope, scope, candidates, graph, ctx)

      assert :ok == DedupGate.decline_review(scope, node)
      assert {:ok, []} = Catalog.list_entries(scope)
      assert {:ok, []} = Catalog.list_pending_reviews(scope)
    end
  end

  describe "exit criterion (issue #66)" do
    test "two independently-produced real Traces anti-unify, pass Admit with fidelity evidence and human review, and become a live CatalogEntry" do
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

      # Two independently-produced real Traces (real wasmtime invocation via
      # the fixture Capability, standing in for 6d-i's own NativeTemplate
      # instances producing real Traces).
      trace1 = ground_greet_trace("alice", "Alice")
      trace2 = ground_greet_trace("bob", "Bob")

      assert {:ok, [{generalization, sub1, sub2}]} = AntiUnifier.generalize(trace1, trace2)
      assert AntiUnifier.substitute(generalization, sub1) == trace1
      assert AntiUnifier.substitute(generalization, sub2) == trace2

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

      assert {:ok, [{:queued, node, :admit}]} =
               DedupGate.propose(scope, scope, [{generalization, sub1, sub2}], graph, ctx)

      assert {:ok, [{^node, pending_review}]} = Catalog.list_pending_reviews(scope)
      assert pending_review.fidelity_evidence == [:fidelity_pass, :fidelity_pass]

      assert :ok == DedupGate.approve_review(scope, scope, node)

      assert {:ok, [{_entry_node, entry}]} = Catalog.list_entries(scope)
      assert entry == rdf_round_trip(generalization)
    end
  end

  describe "propose/5 — target_scope and review_scope differ" do
    test "a Hub-targeted proposal is classified/admitted against target_scope but reviewed in review_scope's own queue" do
      FakeStore.start(%{
        {"acme", ["capabilities", "greetPerson"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      target_scope = :hub
      review_scope = unique_tenant()
      # :hub is shared and disk-persisted across every test run in this
      # suite (never force-deleted — see catalog_test.exs's own "Hub vs.
      # Tenant scope isolation" test for why). A unique predicate per test
      # run keeps classify/2 from ever seeing a stale entry left behind by
      # an earlier run and misclassifying this as :merge instead of :admit.
      predicate_local_name = "propose5admit#{System.unique_integer([:positive])}"

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(review_scope))
      end)

      trace1 = ground_greet_trace("alice", "Alice", predicate_local_name)
      trace2 = ground_greet_trace("bob", "Bob", predicate_local_name)

      assert {:ok, [{generalization, _sub1, _sub2}] = candidates} =
               AntiUnifier.generalize(trace1, trace2)

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

      assert {:ok, [{:queued, node, :admit}]} =
               DedupGate.propose(target_scope, review_scope, candidates, graph, ctx)

      # Reviewed in review_scope's own queue, not target_scope's.
      assert {:ok, review_entries} = Catalog.list_pending_reviews(review_scope)
      assert Enum.any?(review_entries, fn {n, _} -> n == node end)

      # Not yet admitted into target_scope.
      assert {:ok, target_entries_before} = Catalog.list_entries(target_scope)
      refute Enum.any?(target_entries_before, fn {_n, rule} -> rule == generalization end)

      assert :ok == DedupGate.approve_review(target_scope, review_scope, node)

      # Admitted into target_scope's Catalog...
      expected_entry = rdf_round_trip(generalization)
      assert {:ok, target_entries_after} = Catalog.list_entries(target_scope)
      assert Enum.any?(target_entries_after, fn {_n, rule} -> rule == expected_entry end)

      # ...and the review resolved in review_scope, not target_scope.
      assert {:ok, []} = Catalog.list_pending_reviews(review_scope)
    end
  end

  describe "PendingReview — :not_applicable fidelity_evidence" do
    test "round-trips through Catalog.queue_pending_review/2 + list_pending_reviews/1" do
      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      pending_review = %PendingReview{
        kind: :admit,
        candidate: sample_install_candidate(),
        fidelity_evidence: :not_applicable,
        replaces: nil
      }

      {:ok, node} = Catalog.queue_pending_review(scope, pending_review)
      assert {:ok, [{^node, ^pending_review}]} = Catalog.list_pending_reviews(scope)
    end
  end

  describe "propose_install/3" do
    test "an install candidate against an empty target Catalog is queued as :admit with :not_applicable evidence" do
      target_scope = unique_tenant()
      review_scope = target_scope

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(review_scope))
      end)

      installed_rule = sample_install_candidate()

      assert {:ok, {:queued, node, :admit}} =
               DedupGate.propose_install(target_scope, review_scope, installed_rule)

      assert {:ok, [{^node, pending_review}]} = Catalog.list_pending_reviews(review_scope)
      assert pending_review.fidelity_evidence == :not_applicable
      assert pending_review.candidate == installed_rule
    end

    test "an install candidate already covered by an existing entry is Rejected, no review queued" do
      target_scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(target_scope))
      end)

      installed_rule = sample_install_candidate()
      :ok = Catalog.admit_entry(target_scope, installed_rule, nil)

      assert {:ok, {:rejected, :already_covered}} =
               DedupGate.propose_install(target_scope, target_scope, installed_rule)
    end
  end
end
