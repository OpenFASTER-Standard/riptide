defmodule Riptide.Derivation.LLMFallbackTest do
  use ExUnit.Case, async: false

  alias Riptide.Capability.Definition
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.LLMFallback

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
    def complete(_prompt) do
      Agent.get(__MODULE__, & &1)
    end

    def start(result) do
      case Agent.start_link(fn -> result end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
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
end
