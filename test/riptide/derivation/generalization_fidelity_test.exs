defmodule Riptide.Derivation.GeneralizationFidelityTest do
  use ExUnit.Case, async: true

  alias Riptide.Capability.Definition
  alias Riptide.Derivation.GeneralizationFidelity
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}
  alias Riptide.Derivation.{Rule, Signature, Var}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

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

  defp greet_definition(name, kind \\ :effect) do
    %Definition{
      name: RDF.iri("urn:riptide:capability:" <> name),
      kind: kind,
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

  describe "check/3 — groundness precondition" do
    test "a fully ground Rule with an empty Body passes trivially" do
      head = %FactPattern{predicate: rel("greeted"), args: [t("alice"), RDF.literal("hi")]}

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: []
      }

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:ok, :fidelity_pass}
    end

    test "a Var anywhere in the Head is rejected as not_ground, even with an empty Body" do
      head = %FactPattern{predicate: rel("greeted"), args: [%Var{name: "X"}, RDF.literal("hi")]}

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: []
      }

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:error, :not_ground}
    end

    test "a Var anywhere in the Body is rejected as not_ground" do
      head = %FactPattern{predicate: rel("greeted"), args: [t("alice"), RDF.literal("hi")]}
      body = [%FactPattern{predicate: rel("worksAt"), args: [%Var{name: "X"}, t("acme")]}]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:error, :not_ground}
    end
  end

  describe "check/3 — FactPattern" do
    test "passes when the fact is present in the graph" do
      head = %FactPattern{predicate: rel("greeted"), args: [t("alice"), RDF.literal("hi")]}
      body = [%FactPattern{predicate: rel("worksAt"), args: [t("alice"), t("acme")]}]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [rel("worksAt")],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      graph = RDF.Graph.new([{t("alice"), rel("worksAt"), t("acme")}])

      assert GeneralizationFidelity.check(rule, graph, context()) == {:ok, :fidelity_pass}
    end

    test "fails with :fact_not_present when the fact is missing from the graph" do
      head = %FactPattern{predicate: rel("greeted"), args: [t("alice"), RDF.literal("hi")]}
      body = [%FactPattern{predicate: rel("worksAt"), args: [t("alice"), t("acme")]}]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [rel("worksAt")],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:ok, {:fidelity_fail, {:fact_not_present, {t("alice"), rel("worksAt"), t("acme")}}}}
    end

    test "short-circuits: a failing first literal is reported without evaluating the second" do
      head = %FactPattern{predicate: rel("greeted"), args: [t("alice"), RDF.literal("hi")]}

      body = [
        %FactPattern{predicate: rel("worksAt"), args: [t("alice"), t("acme")]},
        %FactPattern{predicate: rel("approved"), args: [t("acme"), t("bob")]}
      ]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [rel("worksAt"), rel("approved")],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      # Neither fact is present — if the second literal were evaluated first
      # or the walk didn't short-circuit, this assertion still pins the
      # *first* literal's reason, proving Body order is respected.
      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:ok, {:fidelity_fail, {:fact_not_present, {t("alice"), rel("worksAt"), t("acme")}}}}
    end
  end

  describe "check/3 — CapabilityReference, :effect kind" do
    test "passes when the fresh invocation matches the recorded result" do
      cap_iri = RDF.iri("urn:riptide:capability:greetAlice")

      FakeStore.start(%{
        {"acme", ["capabilities", "greetAlice"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      head = %FactPattern{predicate: rel("greeted"), args: [t("riptide"), "\"Hello, Alice!\""]}

      body = [
        %CapabilityReference{
          capability: cap_iri,
          args: [RDF.literal("Alice")],
          result: "\"Hello, Alice!\""
        }
      ]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      ctx = context(%{capabilities: %{cap_iri => greet_definition("greetAlice")}})

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), ctx) == {:ok, :fidelity_pass}
    end

    test "fails with :capability_mismatch when the fresh invocation differs from the recorded result" do
      cap_iri = RDF.iri("urn:riptide:capability:greetAlice")

      FakeStore.start(%{
        {"acme", ["capabilities", "greetAlice"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      head = %FactPattern{
        predicate: rel("greeted"),
        args: [t("riptide"), "\"stale recorded value\""]
      }

      body = [
        %CapabilityReference{
          capability: cap_iri,
          args: [RDF.literal("Alice")],
          result: "\"stale recorded value\""
        }
      ]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      ctx = context(%{capabilities: %{cap_iri => greet_definition("greetAlice")}})

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), ctx) ==
               {:ok,
                {:fidelity_fail,
                 {:capability_mismatch, cap_iri, "\"stale recorded value\"", "\"Hello, Alice!\""}}}
    end

    test "fails with :capability_error when the invocation itself errors (unauthorized)" do
      cap_iri = RDF.iri("urn:riptide:capability:notGranted")
      FakeStore.start(%{})

      head = %FactPattern{predicate: rel("greeted"), args: [t("riptide"), "\"Hello, Alice!\""]}

      body = [
        %CapabilityReference{
          capability: cap_iri,
          args: [RDF.literal("Alice")],
          result: "\"Hello, Alice!\""
        }
      ]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      ctx = context(%{capabilities: %{cap_iri => greet_definition("notGranted")}})

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), ctx) ==
               {:ok, {:fidelity_fail, {:capability_error, cap_iri, :unauthorized}}}
    end

    test "an unresolvable capability IRI is rejected as a structural error" do
      cap_iri = RDF.iri("urn:riptide:capability:notRegistered")
      head = %FactPattern{predicate: rel("greeted"), args: [t("riptide"), "\"Hello, Alice!\""]}

      body = [
        %CapabilityReference{
          capability: cap_iri,
          args: [RDF.literal("Alice")],
          result: "\"Hello, Alice!\""
        }
      ]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:error, {:unresolvable, cap_iri}}
    end
  end

  describe "check/3 — CapabilityReference, :observe kind" do
    test "never invokes — trusts the recorded result even with a Definition that would error if invoked" do
      cap_iri = RDF.iri("urn:riptide:capability:externalPriceFeed")

      # component intentionally points at a nonexistent file. If check/3
      # ever actually invoked this (a regression), Capability.invoke/4
      # would return {:error, {:trap, _}} and this test would fail on the
      # {:ok, :fidelity_pass} assertion below — proving non-invocation
      # rather than merely asserting it.
      definition = %Definition{
        name: cap_iri,
        kind: :observe,
        component: "test/fixtures/riptide_capability/does_not_exist.wasm",
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

      head = %FactPattern{predicate: rel("observed"), args: [t("riptide"), "\"stale but trusted\""]}

      body = [
        %CapabilityReference{
          capability: cap_iri,
          args: [RDF.literal("Alice")],
          result: "\"stale but trusted\""
        }
      ]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      # No FakeStore policy is registered at all — an :effect invocation
      # would also fail authorization first, doubling the proof that this
      # path never reaches Capability.invoke/4.
      ctx = context(%{capabilities: %{cap_iri => definition}})

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), ctx) == {:ok, :fidelity_pass}
    end
  end
end
