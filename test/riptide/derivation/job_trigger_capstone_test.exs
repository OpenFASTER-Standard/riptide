defmodule Riptide.Derivation.JobTriggerCapstoneTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.Derivation.{Catalog, Job}

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify(_token), do: {:error, :invalid_token}
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
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    dir = Path.join(System.tmp_dir!(), "job_capstone_#{System.unique_integer([:positive])}")
    Riptide.AppEnvTestHelpers.put_env(:riptide, :blob_data_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  test "exit criterion: register+approve a Capability via real HTTP, write a Job, watch it execute" do
    tenant_id = "job-capstone-" <> Uniq.UUID.uuid4()
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
      Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id))
    end)

    name =
      "urn:riptide:capability:capstone-restart-payments-#{System.unique_integer([:positive])}"

    component_bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")

    body =
      Jason.encode!(%{
        "name" => name,
        "kind" => "effect",
        "function" => "greet",
        "fuel_limit" => 100_000_000,
        "timeout_ms" => 5_000,
        "memory_limits" => %{
          "max_memory_size" => nil,
          "max_table_elements" => nil,
          "max_instances" => nil,
          "max_tables" => nil
        },
        "component_bytes" => Base.encode64(component_bytes)
      })

    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capabilities", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert propose_conn.status == 200
    node_id = Jason.decode!(propose_conn.resp_body)["node_id"]

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capability-reviews/#{node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)
    local_name = String.trim_leading(name, "urn:riptide:capability:")

    FakeStore.start(%{
      {tenant_id, ["capabilities", local_name]} => [
        %Policy{effect: :allow, modes: [:invoke], matcher: :public}
      ]
    })

    job = %Job{
      tenant_id: tenant_id,
      status: :pending,
      reference: {:capability, RDF.iri(name)},
      args: [RDF.literal("World")],
      job_graph: nil,
      result: nil,
      error: nil
    }

    assert {:ok, job_node} = Catalog.write_job(tenant_id, job)
    stream_id = Catalog.job_stream_id(tenant_id)

    assert eventually(fn ->
             case Catalog.list_jobs(stream_id) do
               {:ok, jobs} ->
                 case Enum.find(jobs, fn {n, _j} -> n == job_node end) do
                   {_n, %{status: :done}} -> true
                   _ -> false
                 end

               _ ->
                 false
             end
           end)

    {:ok, jobs} = Catalog.list_jobs(stream_id)
    {_n, final_job} = Enum.find(jobs, fn {n, _j} -> n == job_node end)
    assert final_job.status == :done
    assert final_job.result == RDF.literal("\"Hello, World!\"")
  end

  defp eventually(fun, attempts_left \\ 100) do
    cond do
      fun.() -> true
      attempts_left <= 1 -> false
      true -> Process.sleep(200) && eventually(fun, attempts_left - 1)
    end
  end
end
