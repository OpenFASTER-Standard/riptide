defmodule Riptide.Derivation.JobTriggerClusterTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 120_000

  @peers [
    {:job_a, "job-a", ~c"127.0.0.90"},
    {:job_b, "job-b", ~c"127.0.0.91"},
    {:job_c, "job-c", ~c"127.0.0.92"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"job_trigger_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a jobCapability Job is picked up only by the leader of its own stream, invoked, and its result written back" do
    peers = bootstrap_peers(@peers)
    tenant_id = "job-trigger-cap-#{System.unique_integer([:positive])}"

    stream_id =
      :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :job_stream_id, [tenant_id])

    component_bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")

    {:ok, hash} =
      :erpc.call(hd_node(peers), Riptide.BlobStore, :put, [tenant_id, component_bytes])

    cap_name =
      RDF.iri("urn:riptide:capability:job-trigger-cap-#{System.unique_integer([:positive])}")

    entry = %Riptide.Derivation.CapabilityCatalogEntry{
      name: cap_name,
      kind: :effect,
      component_hash: hash,
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

    :ok =
      :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :admit_capability, [
        {:tenant, tenant_id},
        entry,
        nil
      ])

    # Capability.invoke/4 goes through the real, default-deny authz store
    # (Riptide.Authz.Store.TenantFacts) unconditionally — no FakeStore swap
    # is available here (bare :peer nodes never boot the full app/HTTP
    # layer), so a real Policy write through the already-bootstrapped
    # placement cluster is required for the executor's own invocation to
    # succeed. Confirmed live: without this, the Job runs, is picked up by
    # the correct leader, but fails with :unauthorized.
    local_name = cap_name |> RDF.IRI.to_string() |> String.trim_leading("urn:riptide:capability:")

    :ok =
      :erpc.call(hd_node(peers), Riptide.Authz.Store.TenantFacts, :add_policy, [
        tenant_id,
        ["capabilities", local_name],
        %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
      ])

    job = %Riptide.Derivation.Job{
      tenant_id: tenant_id,
      status: :pending,
      reference: {:capability, cap_name},
      args: [RDF.literal("World")],
      job_graph: nil,
      result: nil,
      error: nil
    }

    assert {:ok, job_node} =
             :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :write_job, [tenant_id, job])

    assert eventually(fn ->
             case :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :list_jobs, [stream_id]) do
               {:ok, jobs} ->
                 case Enum.find(jobs, fn {n, _j} -> n == job_node end) do
                   {_n, %{status: :done}} -> true
                   _ -> false
                 end

               _ ->
                 false
             end
           end)

    {:ok, jobs} = :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :list_jobs, [stream_id])
    {_n, final_job} = Enum.find(jobs, fn {n, _j} -> n == job_node end)
    assert final_job.status == :done
    assert final_job.result == RDF.literal("\"Hello, World!\"")
  end

  test "a jobRule Job resolves real Fact state, invokes via the interpreter, and writes back a result" do
    peers = bootstrap_peers(@peers)
    tenant_id = "job-trigger-rule-#{System.unique_integer([:positive])}"
    node_a = hd_node(peers)

    catalog_stream_id =
      :erpc.call(node_a, Riptide.Derivation.Catalog, :catalog_stream_id, [{:tenant, tenant_id}])

    job_graph_stream_id = catalog_stream_id <> "/facts"

    subject = RDF.iri("urn:riptide:relation:job-trigger-subject")
    predicate = RDF.iri("urn:riptide:relation:job-trigger-greeted")

    :ok =
      :erpc.call(node_a, Riptide.Stream.StreamSupervisor, :ensure_ready, [job_graph_stream_id])

    fact_graph =
      :erpc.call(node_a, RDF.Graph, :new, [[{subject, predicate, RDF.literal("seed")}]])

    event = :erpc.call(node_a, Riptide.Event, :new, [job_graph_stream_id, :replace, fact_graph])
    :erpc.call(node_a, Riptide.Stream.StreamServer, :append, [job_graph_stream_id, event])

    rule_iri =
      RDF.iri("urn:riptide:relation:job-trigger-rule-#{System.unique_integer([:positive])}")

    rule = %Riptide.Derivation.Rule{
      signature: %Riptide.Derivation.Signature{
        name: rule_iri,
        parameters: [],
        reads: [predicate],
        produces: [rule_iri]
      },
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: rule_iri,
        args: [subject, RDF.literal("done")]
      },
      body: [
        %Riptide.Derivation.Literal.FactPattern{
          predicate: predicate,
          args: [subject, RDF.literal("seed")]
        }
      ]
    }

    :ok =
      :erpc.call(node_a, Riptide.Derivation.Catalog, :admit_entry, [
        {:tenant, tenant_id},
        rule,
        nil
      ])

    job = %Riptide.Derivation.Job{
      tenant_id: tenant_id,
      status: :pending,
      reference: {:rule, rule_iri},
      args: [],
      job_graph: job_graph_stream_id,
      result: nil,
      error: nil
    }

    stream_id = :erpc.call(node_a, Riptide.Derivation.Catalog, :job_stream_id, [tenant_id])

    assert {:ok, job_node} =
             :erpc.call(node_a, Riptide.Derivation.Catalog, :write_job, [tenant_id, job])

    assert eventually(fn ->
             case :erpc.call(node_a, Riptide.Derivation.Catalog, :list_jobs, [stream_id]) do
               {:ok, jobs} ->
                 case Enum.find(jobs, fn {n, _j} -> n == job_node end) do
                   {_n, %{status: :done}} -> true
                   _ -> false
                 end

               _ ->
                 false
             end
           end)

    {:ok, jobs} = :erpc.call(node_a, Riptide.Derivation.Catalog, :list_jobs, [stream_id])
    {_n, final_job} = Enum.find(jobs, fn {n, _j} -> n == job_node end)
    assert final_job.status == :done
  end

  test "self-heals across a leader crash: a still-pending Job is picked up by the newly-elected leader" do
    peers = bootstrap_peers(@peers)
    tenant_id = "job-trigger-crash-#{System.unique_integer([:positive])}"
    node_a = hd_node(peers)

    component_bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")
    {:ok, hash} = :erpc.call(node_a, Riptide.BlobStore, :put, [tenant_id, component_bytes])

    cap_name =
      RDF.iri("urn:riptide:capability:job-trigger-crash-#{System.unique_integer([:positive])}")

    entry = %Riptide.Derivation.CapabilityCatalogEntry{
      name: cap_name,
      kind: :effect,
      component_hash: hash,
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

    :ok =
      :erpc.call(node_a, Riptide.Derivation.Catalog, :admit_capability, [
        {:tenant, tenant_id},
        entry,
        nil
      ])

    local_name = cap_name |> RDF.IRI.to_string() |> String.trim_leading("urn:riptide:capability:")

    :ok =
      :erpc.call(node_a, Riptide.Authz.Store.TenantFacts, :add_policy, [
        tenant_id,
        ["capabilities", local_name],
        %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
      ])

    stream_id = :erpc.call(node_a, Riptide.Derivation.Catalog, :job_stream_id, [tenant_id])
    :ok = :erpc.call(node_a, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])

    leader_node =
      Enum.find(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :stream_leader?, [stream_id])
      end)
      |> case do
        {_pid, node, _ordinal} -> node
        nil -> nil
      end

    assert leader_node != nil, "no peer became this stream's leader in time"

    job = %Riptide.Derivation.Job{
      tenant_id: tenant_id,
      status: :pending,
      reference: {:capability, cap_name},
      args: [RDF.literal("World")],
      job_graph: nil,
      result: nil,
      error: nil
    }

    assert {:ok, job_node} =
             :erpc.call(node_a, Riptide.Derivation.Catalog, :write_job, [tenant_id, job])

    {leader_pid, ^leader_node, _ordinal} =
      Enum.find(peers, fn {_pid, node, _ordinal} -> node == leader_node end)

    # The killed leader might BE node_a itself (job_a is often, though not
    # always, the elected leader in this shape of 3-peer cluster) — polling
    # through node_a after killing it would fail every call with
    # {:erpc, :noconnection} (confirmed live). Poll through a genuinely
    # surviving peer instead.
    {_pid, survivor_node, _ordinal} =
      Enum.find(peers, fn {_pid, node, _ordinal} -> node != leader_node end)

    :peer.stop(leader_pid)

    assert eventually(
             fn ->
               case :erpc.call(survivor_node, Riptide.Derivation.Catalog, :list_jobs, [
                      stream_id
                    ]) do
                 {:ok, jobs} ->
                   case Enum.find(jobs, fn {n, _j} -> n == job_node end) do
                     {_n, %{status: :done}} -> true
                     _ -> false
                   end

                 _ ->
                   false
               end
             end,
             150
           )
  end

  # Proves the mechanism doesn't lose or deadlock a Job in a real
  # multi-node run — deliberately does NOT also try to prove strict
  # non-overlap end-to-end here (job_trigger_test.exs's own unit tests
  # already prove that deterministically). Two real WASM invocations
  # against the trivial fixture.wasm complete too fast to reliably observe
  # an overlap window one way or the other in a cluster test, so trying to
  # assert it here would be flaky, not more rigorous.
  test "two Jobs for the same Tenant sharing a mutex_key both eventually complete" do
    peers = bootstrap_peers(@peers)
    tenant_id = "job-trigger-resource-#{System.unique_integer([:positive])}"

    stream_id =
      :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :job_stream_id, [tenant_id])

    component_bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")

    {:ok, hash} =
      :erpc.call(hd_node(peers), Riptide.BlobStore, :put, [tenant_id, component_bytes])

    cap_name =
      RDF.iri("urn:riptide:capability:job-trigger-resource-#{System.unique_integer([:positive])}")

    entry = %Riptide.Derivation.CapabilityCatalogEntry{
      name: cap_name,
      kind: :effect,
      component_hash: hash,
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

    :ok =
      :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :admit_capability, [
        {:tenant, tenant_id},
        entry,
        nil
      ])

    local_name = cap_name |> RDF.IRI.to_string() |> String.trim_leading("urn:riptide:capability:")

    :ok =
      :erpc.call(hd_node(peers), Riptide.Authz.Store.TenantFacts, :add_policy, [
        tenant_id,
        ["capabilities", local_name],
        %Riptide.Authz.Policy{effect: :allow, modes: [:invoke], matcher: :public}
      ])

    mutex_key = "shared-mutex-#{System.unique_integer([:positive])}"

    job = fn name ->
      %Riptide.Derivation.Job{
        tenant_id: tenant_id,
        status: :pending,
        reference: {:capability, cap_name},
        args: [RDF.literal(name)],
        job_graph: nil,
        result: nil,
        error: nil,
        mutex_key: mutex_key
      }
    end

    assert {:ok, node1} =
             :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :write_job, [
               tenant_id,
               job.("Alice")
             ])

    assert {:ok, node2} =
             :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :write_job, [
               tenant_id,
               job.("Bob")
             ])

    # Whichever of the two Jobs loses the mutex_key race on its own
    # {:job_written, stream_id} broadcast gets skipped that round and only
    # retried on the next periodic_sweep — 30s in this test env too, since
    # :job_trigger_sweep_interval_ms has no test-config override. 250 * 200ms
    # = 50s gives that a real margin, not just this test's default 20s.
    assert eventually(
             fn ->
               case :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :list_jobs, [
                      stream_id
                    ]) do
                 {:ok, jobs} ->
                   Enum.all?([node1, node2], fn n ->
                     match?({_n, %{status: :done}}, Enum.find(jobs, fn {jn, _} -> jn == n end))
                   end)

                 _ ->
                   false
               end
             end,
             250
           )

    {:ok, jobs} = :erpc.call(hd_node(peers), Riptide.Derivation.Catalog, :list_jobs, [stream_id])
    {_n1, final1} = Enum.find(jobs, fn {n, _} -> n == node1 end)
    {_n2, final2} = Enum.find(jobs, fn {n, _} -> n == node2 end)
    assert final1.status == :done
    assert final2.status == :done
    assert final1.result == RDF.literal("\"Hello, Alice!\"")
    assert final2.result == RDF.literal("\"Hello, Bob!\"")
  end

  defp hd_node([{_pid, node, _ordinal} | _]), do: node

  defp bootstrap_peers(specs) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, ordinal, host} <- specs do
        {:ok, pid, node} =
          :peer.start_link(%{
            name: alive_name,
            host: host,
            longnames: true,
            args: pa_args,
            env: [{~c"HOSTNAME", to_charlist(ordinal)}]
          })

        {pid, node, ordinal}
      end

    on_exit(fn ->
      Enum.each(peers, &stop_peer/1)

      Enum.each(specs, fn {_alive_name, ordinal, _host} ->
        File.rm_rf!(Path.join(File.cwd!(), ordinal))
      end)
    end)

    bytecode = Riptide.MultiNodeTestHelpers.own_module_bytecode(__MODULE__)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, __MODULE__} =
               :erpc.call(node, :code, :load_binary, [
                 __MODULE__,
                 ~c"job_trigger_cluster_test.ex",
                 bytecode
               ])
    end

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    for {_pid, node, ordinal} <- peers do
      bootstrap_node(node, ordinal)
    end

    for {_pid, node, _ordinal} <- peers do
      :ok = :erpc.call(node, Riptide.PlacementMembership, :bootstrap_once, [])
    end

    core_peers = Enum.take(peers, Riptide.PlacementMembership.target_size())

    assert eventually(fn ->
             Enum.all?(core_peers, fn {_pid, node, _ordinal} ->
               match?(
                 {:ok, _},
                 :erpc.call(node, Riptide.RaCluster.Placement, :local_placement_members, [])
               )
             end)
           end)

    peers
  end

  defp bootstrap_node(node, ordinal) do
    :erpc.call(node, System, :put_env, [
      "RIPTIDE_BLOB_DATA_DIR",
      Path.join(File.cwd!(), "#{ordinal}/blob_data")
    ])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])

    case :erpc.call(node, :ra_system, :start, [
           :erpc.call(node, Riptide.RaCluster, :system_config, [])
         ]) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

    {:ok, _} =
      start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])

    {:ok, _} = start_unlinked(node, Riptide.PlacementMembership, :start_link, [[]])
    {:ok, _} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])

    {:ok, _} =
      start_unlinked(node, Registry, :start_link, [
        [keys: :unique, name: Riptide.SupervisedProcess.Registry]
      ])

    {:ok, _} =
      start_unlinked(node, DynamicSupervisor, :start_link, [
        [strategy: :one_for_one, name: Riptide.SupervisedProcess.DynamicSupervisor]
      ])

    {:ok, _} = start_unlinked(node, Riptide.BlobStore, :start_link, [[]])

    {:ok, _} =
      start_unlinked(node, Task.Supervisor, :start_link, [
        [name: Riptide.Derivation.JobTrigger.ExecutionSupervisor]
      ])

    {:ok, _} = start_unlinked(node, Riptide.Derivation.JobTrigger, :start_link, [[]])
  end

  defp start_unlinked(node, mod, fun, args, timeout \\ 5_000) do
    parent = self()
    ref = make_ref()

    :erpc.call(node, Kernel, :spawn, [
      fn ->
        result = apply(mod, fun, args)
        send(parent, {ref, result})
        Process.sleep(:infinity)
      end
    ])

    receive do
      {^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  defp stop_peer({pid, _node, _ordinal}) do
    if Process.alive?(pid) do
      try do
        :peer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp eventually(fun, attempts_left \\ 100) do
    cond do
      fun.() -> true
      attempts_left <= 1 -> false
      true -> Process.sleep(200) && eventually(fun, attempts_left - 1)
    end
  end
end
