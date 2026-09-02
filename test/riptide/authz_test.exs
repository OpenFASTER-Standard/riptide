defmodule Riptide.AuthzTest do
  use ExUnit.Case, async: false

  alias Riptide.Authz
  alias Riptide.Authz.Policy

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies(tenant_id, path_prefix) do
      Agent.get(__MODULE__, &Map.get(&1, {tenant_id, path_prefix}, []))
    end

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok

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

  test "denies when no policy matches at all (default-deny)" do
    FakeStore.start(%{})
    assert Authz.evaluate({:tenant, "acme"}, ["docs"], %{"sub" => "user-1"}, :read) == :deny
  end

  test "a :public matcher allows anyone, including anonymous, for the modes it lists" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
    })

    assert Authz.evaluate({:tenant, "acme"}, ["docs"], nil, :read) == :allow
    assert Authz.evaluate({:tenant, "acme"}, ["docs"], %{"sub" => "someone"}, :read) == :allow
    assert Authz.evaluate({:tenant, "acme"}, ["docs"], nil, :write) == :deny
  end

  test "an :authenticated matcher allows any non-nil subject but not anonymous" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :authenticated}]
    })

    assert Authz.evaluate({:tenant, "acme"}, ["docs"], %{"sub" => "someone"}, :read) == :allow
    assert Authz.evaluate({:tenant, "acme"}, ["docs"], nil, :read) == :deny
  end

  test "an {:agent, subject} matcher only allows that exact subject" do
    FakeStore.start(%{
      {"acme", []} => [
        %Policy{effect: :allow, modes: [:read, :write], matcher: {:agent, "owner"}}
      ]
    })

    assert Authz.evaluate({:tenant, "acme"}, ["docs"], %{"sub" => "owner"}, :write) == :allow

    assert Authz.evaluate({:tenant, "acme"}, ["docs"], %{"sub" => "someone-else"}, :write) ==
             :deny
  end

  test "a policy only grants the modes it explicitly lists" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
    })

    assert Authz.evaluate({:tenant, "acme"}, ["docs"], nil, :read) == :allow
    assert Authz.evaluate({:tenant, "acme"}, ["docs"], nil, :write) == :deny
  end

  test "deny overrides allow when both match the same request" do
    FakeStore.start(%{
      {"acme", []} => [
        %Policy{effect: :allow, modes: [:read], matcher: :public},
        %Policy{effect: :deny, modes: [:read], matcher: :authenticated}
      ]
    })

    # Anonymous: only the :public allow matches -> allow.
    assert Authz.evaluate({:tenant, "acme"}, ["docs"], nil, :read) == :allow
    # Authenticated: both the :public allow and the :authenticated deny match -> deny wins.
    assert Authz.evaluate({:tenant, "acme"}, ["docs"], %{"sub" => "someone"}, :read) == :deny
  end

  test "a policy on an ancestor container is inherited by a deeper resource" do
    FakeStore.start(%{
      {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
    })

    assert Authz.evaluate({:tenant, "acme"}, ["docs", "sub", "deep"], nil, :read) == :allow
  end

  test "a policy on a sibling path prefix does not apply to an unrelated resource" do
    FakeStore.start(%{
      {"acme", ["other"]} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
    })

    assert Authz.evaluate({:tenant, "acme"}, ["docs"], nil, :read) == :deny
  end

  describe "evaluate_with_matcher/4" do
    test "returns {:allow, matcher} for the specific policy that matched" do
      FakeStore.start(%{
        {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]
      })

      assert Authz.evaluate_with_matcher({:tenant, "acme"}, [], nil, :read) ==
               {:allow, :public}
    end

    test "returns :deny when nothing matches" do
      FakeStore.start(%{})

      assert Authz.evaluate_with_matcher({:tenant, "acme"}, [], nil, :read) == :deny
    end

    test "an explicit deny policy still wins over an allow, same as evaluate/4" do
      FakeStore.start(%{
        {"acme", []} => [
          %Policy{effect: :allow, modes: [:read], matcher: :public},
          %Policy{effect: :deny, modes: [:read], matcher: :public}
        ]
      })

      assert Authz.evaluate_with_matcher({:tenant, "acme"}, [], nil, :read) == :deny
    end

    test "returns the {:agent, subject} matcher, not just :allow, for an owner-matched policy" do
      FakeStore.start(%{
        {"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: {:agent, "owner"}}]
      })

      assert Authz.evaluate_with_matcher({:tenant, "acme"}, [], %{"sub" => "owner"}, :read) ==
               {:allow, {:agent, "owner"}}
    end
  end

  describe "evaluate/4 still returns a plain :allow/:deny (unchanged public contract)" do
    test "allow" do
      FakeStore.start(%{{"acme", []} => [%Policy{effect: :allow, modes: [:read], matcher: :public}]})
      assert Authz.evaluate({:tenant, "acme"}, [], nil, :read) == :allow
    end

    test "deny" do
      FakeStore.start(%{})
      assert Authz.evaluate({:tenant, "acme"}, [], nil, :read) == :deny
    end
  end
end
