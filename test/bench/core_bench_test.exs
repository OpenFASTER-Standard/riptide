# Elixir-level Benchee micro-benchmarks for the primitives the HTTP layer is
# built on. Tagged :benchmark and excluded by default (see
# test/test_helper.exs's own ExUnit.configure/1 call) so a normal `mix
# test`/CI run never executes this multi-second Benchee run. Run explicitly:
#
#   mix test test/bench/core_bench_test.exs --include benchmark --trace
#
# `--include benchmark` opts back into this one file's tagged test;
# `--trace` runs synchronously with unbounded per-test output, which reads
# better for a benchmark's own multi-line console report than the default
# dotted progress output. Reuses the exact same app bootstrap every other
# test in this suite does (test/test_helper.exs) — no separate
# distribution/timing setup to get subtly wrong.
defmodule Riptide.Bench.CoreBench do
  use ExUnit.Case, async: false

  @moduletag :benchmark
  @moduletag timeout: :infinity

  alias Riptide.{Authz, Event, Placement}
  alias Riptide.Authz.Policy
  alias Riptide.Authz.Store.TenantFacts
  alias Riptide.RDF.{Patch, TurtleCodec}
  alias Riptide.Stream.StreamServer

  test "core primitive benchmarks" do
    small_graph =
      RDF.Graph.new()
      |> RDF.Graph.add({RDF.iri("https://ex.org/s"), RDF.iri("https://ex.org/p"), "small value"})

    medium_graph =
      Enum.reduce(1..50, RDF.Graph.new(), fn n, acc ->
        RDF.Graph.add(
          acc,
          {RDF.iri("https://ex.org/s"), RDF.iri("https://ex.org/p#{n}"), "value #{n}"}
        )
      end)

    {:ok, small_turtle} = TurtleCodec.encode(small_graph)
    {:ok, medium_turtle} = TurtleCodec.encode(medium_graph)

    prepare_stream = fn history_size ->
      stream_id = "bench-get-since-#{history_size}-" <> Uniq.UUID.uuid4()
      {:ok, _pid} = StreamServer.start_link(stream_id)

      for _ <- 1..history_size do
        StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
      end

      stream_id
    end

    get_since_10 = prepare_stream.(10)
    get_since_100 = prepare_stream.(100)
    get_since_1000 = prepare_stream.(1000)

    authz_tenant = "bench-authz-tenant-" <> Uniq.UUID.uuid4()

    :ok =
      TenantFacts.add_policy(authz_tenant, [], %Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: :public
      })

    placement_stream_id = "bench-placement-lookup-" <> Uniq.UUID.uuid4()
    {:ok, _pid} = StreamServer.start_link(placement_stream_id)
    # Warm the linearizable lookup once outside the timed run — the
    # benchmark measures steady-state lookup cost, not first-resolve.
    _ = Placement.lookup(placement_stream_id)

    # append/2 gets a fresh stream per Benchee invocation (Benchee re-runs
    # the job function repeatedly) so sequence numbers/history size don't
    # grow unboundedly across iterations and skew later ones.
    fresh_stream_id = fn -> "bench-append-" <> Uniq.UUID.uuid4() end

    IO.puts("\n== Riptide core-primitive benchmarks ==\n")

    Benchee.run(
      %{
        "TurtleCodec.encode/1 (small graph, 1 triple)" => fn ->
          TurtleCodec.encode(small_graph)
        end,
        "TurtleCodec.encode/1 (medium graph, 50 triples)" => fn ->
          TurtleCodec.encode(medium_graph)
        end,
        "TurtleCodec.decode/1 (small graph, 1 triple)" => fn ->
          TurtleCodec.decode(small_turtle)
        end,
        "TurtleCodec.decode/1 (medium graph, 50 triples)" => fn ->
          TurtleCodec.decode(medium_turtle)
        end,
        "Patch.apply/2 (1 addition + 1 removal)" => fn ->
          Patch.apply(small_graph, %Patch{
            additions: [{RDF.iri("https://ex.org/s"), RDF.iri("https://ex.org/p2"), "v2"}],
            removals: [{RDF.iri("https://ex.org/s"), RDF.iri("https://ex.org/p"), "small value"}]
          })
        end,
        "StreamServer.append/2 (:replace, empty graph)" => {
          fn stream_id ->
            StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
          end,
          before_each: fn _ ->
            stream_id = fresh_stream_id.()
            {:ok, _pid} = StreamServer.start_link(stream_id)
            stream_id
          end
        },
        "StreamServer.get_since/2 (10-event history, full read)" => fn ->
          StreamServer.get_since(get_since_10, 0)
        end,
        "StreamServer.get_since/2 (100-event history, full read)" => fn ->
          StreamServer.get_since(get_since_100, 0)
        end,
        "StreamServer.get_since/2 (1000-event history, full read)" => fn ->
          StreamServer.get_since(get_since_1000, 0)
        end,
        "StreamServer.get_since/2 (1000-event history, tail read: cursor 999)" => fn ->
          StreamServer.get_since(get_since_1000, 999)
        end,
        "Placement.lookup/1 (cached-cluster hot path)" => fn ->
          Placement.lookup(placement_stream_id)
        end,
        "Authz.evaluate/4 (single :public policy, depth-1 path)" => fn ->
          Authz.evaluate({:tenant, authz_tenant}, ["doc"], nil, :read)
        end
      },
      time: 3,
      warmup: 1,
      memory_time: 1,
      formatters: [
        {Benchee.Formatters.Console, extended_statistics: true}
      ]
    )
  end
end
