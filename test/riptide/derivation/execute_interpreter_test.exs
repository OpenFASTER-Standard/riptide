defmodule Riptide.Derivation.ExecuteInterpreterTest do
  # async: false — FakeStore is a single, fixed-named Agent shared by every
  # test in this module; running them concurrently races start/stop against
  # each other (see test/riptide/capability_test.exs, which established
  # this same pattern for the same reason).
  use ExUnit.Case, async: false

  alias Riptide.Capability.Definition
  alias Riptide.Derivation.ExecuteInterpreter
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

  defp greet_capability_definition(name) do
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

  describe "call_template/3 — fact-pattern-only Bodies" do
    test "a single fact-pattern literal concludes one triple per match" do
      head = %FactPattern{predicate: rel("sibling"), args: [%Var{name: "X"}, %Var{name: "Y"}]}
      body = [%FactPattern{predicate: rel("worksAt"), args: [%Var{name: "X"}, %Var{name: "Y"}]}]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: head.args,
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      graph = RDF.Graph.new([{t("alice"), rel("worksAt"), t("acme")}])

      assert ExecuteInterpreter.call_template(rule, graph, context()) ==
               {:ok, [{t("alice"), rel("sibling"), t("acme")}]}
    end

    test "a fact-pattern run with zero matches returns {:ok, []}, not an error" do
      head = %FactPattern{predicate: rel("sibling"), args: [%Var{name: "X"}, %Var{name: "Y"}]}
      body = [%FactPattern{predicate: rel("worksAt"), args: [%Var{name: "X"}, %Var{name: "Y"}]}]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: head.args,
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), context()) == {:ok, []}
    end
  end

  describe "call_template/3 — structural checks" do
    test "an unresolvable capability IRI is rejected before any graph access" do
      head = %FactPattern{predicate: rel("out"), args: [t("x"), %Var{name: "Result"}]}

      body = [
        %CapabilityReference{
          capability: RDF.iri("urn:riptide:capability:notRegistered"),
          args: [t("x")],
          result: %Var{name: "Result"}
        }
      ]

      rule = %Rule{
        signature: %Signature{name: head.predicate, parameters: [], reads: [], produces: [head.predicate]},
        head: head,
        body: body
      }

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), context()) ==
               {:error, {:unresolvable, RDF.iri("urn:riptide:capability:notRegistered")}}
    end

    test "an unresolvable rule IRI is rejected before any graph access" do
      head = %FactPattern{predicate: rel("out"), args: [t("x"), %Var{name: "Result"}]}

      body = [
        %RuleReference{
          rule: RDF.iri("urn:riptide:rule:notRegistered"),
          args: [t("x")],
          result: %Var{name: "Result"}
        }
      ]

      rule = %Rule{
        signature: %Signature{name: head.predicate, parameters: [], reads: [], produces: [head.predicate]},
        head: head,
        body: body
      }

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), context()) ==
               {:error, {:unresolvable, RDF.iri("urn:riptide:rule:notRegistered")}}
    end

    test "a RuleReference with more than one arg is rejected as unsupported arity" do
      nested_iri = RDF.iri("urn:riptide:rule:nested")
      head = %FactPattern{predicate: rel("out"), args: [t("x"), %Var{name: "Result"}]}

      body = [
        %RuleReference{
          rule: nested_iri,
          args: [t("x"), t("y")],
          result: %Var{name: "Result"}
        }
      ]

      rule = %Rule{
        signature: %Signature{name: head.predicate, parameters: [], reads: [], produces: [head.predicate]},
        head: head,
        body: body
      }

      nested_rule = %Rule{
        signature: %Signature{name: nested_iri, parameters: [], reads: [], produces: [nested_iri]},
        head: %FactPattern{predicate: nested_iri, args: [%Var{name: "A"}, %Var{name: "B"}]},
        body: [%FactPattern{predicate: rel("f"), args: [%Var{name: "A"}, %Var{name: "B"}]}]
      }

      ctx = context(%{rules: %{nested_iri => nested_rule}})

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), ctx) ==
               {:error, {:unsupported_arity, nested_iri}}
    end
  end

  describe "call_template/3 — CapabilityReference" do
    test "a bare NativeTemplate (single CapabilityReference Body) invoked directly" do
      cap_iri = RDF.iri("urn:riptide:capability:greetSomeone")

      FakeStore.start(%{
        {"acme", ["capabilities", "greetSomeone"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      head = %FactPattern{predicate: rel("greeted"), args: [t("riptide"), %Var{name: "Greeting"}]}

      body = [
        %CapabilityReference{
          capability: cap_iri,
          args: [RDF.literal("Riptide")],
          result: %Var{name: "Greeting"}
        }
      ]

      rule = %Rule{
        signature: %Signature{name: head.predicate, parameters: [], reads: [], produces: [head.predicate]},
        head: head,
        body: body
      }

      ctx = context(%{capabilities: %{cap_iri => greet_capability_definition("greetSomeone")}})

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), ctx) ==
               {:ok, [{t("riptide"), rel("greeted"), "\"Hello, Riptide!\""}]}
    end

    test "a Capability invocation that fails authorization drops the branch and logs a warning" do
      import ExUnit.CaptureLog

      cap_iri = RDF.iri("urn:riptide:capability:notGranted")
      FakeStore.start(%{})

      head = %FactPattern{predicate: rel("greeted"), args: [t("riptide"), %Var{name: "Greeting"}]}

      body = [
        %CapabilityReference{
          capability: cap_iri,
          args: [RDF.literal("Riptide")],
          result: %Var{name: "Greeting"}
        }
      ]

      rule = %Rule{
        signature: %Signature{name: head.predicate, parameters: [], reads: [], produces: [head.predicate]},
        head: head,
        body: body
      }

      ctx = context(%{capabilities: %{cap_iri => greet_capability_definition("notGranted")}})

      log =
        capture_log(fn ->
          assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), ctx) == {:ok, []}
        end)

      assert log =~ "notGranted"
    end
  end

  describe "call_template/3 — RuleReference" do
    test "a RuleReference to a nested Rule whose own fact-pattern run yields multiple bindings" do
      nested_iri = RDF.iri("urn:riptide:rule:colleagueOf")

      nested_rule = %Rule{
        signature: %Signature{
          name: nested_iri,
          parameters: [%Var{name: "Person"}, %Var{name: "Org"}],
          reads: [rel("worksAt")],
          produces: [nested_iri]
        },
        head: %FactPattern{predicate: nested_iri, args: [%Var{name: "Person"}, %Var{name: "Org"}]},
        body: [%FactPattern{predicate: rel("worksAt"), args: [%Var{name: "Person"}, %Var{name: "Org"}]}]
      }

      outer_head = %FactPattern{predicate: rel("lookup"), args: [t("alice"), %Var{name: "Result"}]}

      outer_body = [
        %RuleReference{rule: nested_iri, args: [t("alice")], result: %Var{name: "Result"}}
      ]

      outer_rule = %Rule{
        signature: %Signature{
          name: outer_head.predicate,
          parameters: [],
          reads: [],
          produces: [outer_head.predicate]
        },
        head: outer_head,
        body: outer_body
      }

      graph =
        RDF.Graph.new([
          {t("alice"), rel("worksAt"), t("acme")},
          {t("alice"), rel("worksAt"), t("contractorco")}
        ])

      ctx = context(%{rules: %{nested_iri => nested_rule}})

      assert {:ok, results} = ExecuteInterpreter.call_template(outer_rule, graph, ctx)

      assert MapSet.new(results) ==
               MapSet.new([
                 {t("alice"), rel("lookup"), t("acme")},
                 {t("alice"), rel("lookup"), t("contractorco")}
               ])
    end

    test "the walking-skeleton shape: a multi-stream join feeding a Capability feeding a RuleReference" do
      deploy_cap_iri = RDF.iri("urn:riptide:capability:deployService")
      notify_cap_iri = RDF.iri("urn:riptide:capability:sendNotification")
      notify_team_iri = RDF.iri("urn:riptide:rule:notifyTeam")

      FakeStore.start(%{
        {"acme", ["capabilities", "deployService"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ],
        {"acme", ["capabilities", "sendNotification"]} => [
          %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
        ]
      })

      notify_team_rule = %Rule{
        signature: %Signature{
          name: notify_team_iri,
          parameters: [%Var{name: "Outcome"}, %Var{name: "Result"}],
          reads: [],
          produces: [notify_team_iri]
        },
        head: %FactPattern{predicate: notify_team_iri, args: [%Var{name: "Outcome"}, %Var{name: "Result"}]},
        body: [
          %CapabilityReference{
            capability: notify_cap_iri,
            args: [%Var{name: "Outcome"}],
            result: %Var{name: "Result"}
          }
        ]
      }

      # pendingDeploy(Svc, Target), approved(Target, Owner) — two fact-pattern
      # literals sharing `Target`, assembled from separately-constructed
      # graphs merged together (matching 6c-i-b's own multi-stream-join
      # golden case style, per this phase's exit criterion).
      deployed_head = %FactPattern{predicate: rel("deployed"), args: [%Var{name: "Svc"}, %Var{name: "Result"}]}

      deployed_body = [
        %FactPattern{predicate: rel("pendingDeploy"), args: [%Var{name: "Svc"}, %Var{name: "Target"}]},
        %FactPattern{predicate: rel("approved"), args: [%Var{name: "Target"}, %Var{name: "Owner"}]},
        %CapabilityReference{
          capability: deploy_cap_iri,
          args: [%Var{name: "Owner"}],
          result: %Var{name: "Outcome"}
        },
        %RuleReference{rule: notify_team_iri, args: [%Var{name: "Outcome"}], result: %Var{name: "Result"}}
      ]

      deployed_rule = %Rule{
        signature: %Signature{
          name: deployed_head.predicate,
          parameters: deployed_head.args,
          reads: [rel("pendingDeploy"), rel("approved")],
          produces: [deployed_head.predicate]
        },
        head: deployed_head,
        body: deployed_body
      }

      pending_deploy_graph = RDF.Graph.new([{t("billing-svc"), rel("pendingDeploy"), t("v2")}])
      approved_graph = RDF.Graph.new([{t("v2"), rel("approved"), t("alice")}])
      graph = RDF.Graph.new() |> RDF.Graph.add(pending_deploy_graph) |> RDF.Graph.add(approved_graph)

      ctx =
        context(%{
          capabilities: %{
            deploy_cap_iri => greet_capability_definition("deployService"),
            notify_cap_iri => greet_capability_definition("sendNotification")
          },
          rules: %{notify_team_iri => notify_team_rule}
        })

      assert {:ok, [{subject, predicate, object}]} =
               ExecuteInterpreter.call_template(deployed_rule, graph, ctx)

      assert subject == t("billing-svc")
      assert predicate == rel("deployed")
      # object is notifyTeam's own concluded result — the wave-encoded
      # greet() output, chained through both capability invocations and
      # the RuleReference. The exact value matters less than proving both
      # 6b-i's substrate (two real Capability invocations) and 6c-i-b's
      # matching (the two-literal join) were genuinely exercised together.
      assert is_binary(object) or match?(%RDF.Literal{}, object)
    end
  end
end
