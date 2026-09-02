# Boots a real, single-node Riptide HTTP server for external load-testing
# (wrk, curl, etc.). Tagged :benchmark and excluded by default (see
# test/test_helper.exs's own ExUnit.configure/1 call) so a normal `mix
# test`/CI run never executes this — it blocks forever on purpose. Run
# explicitly, and drive it with wrk/curl from a separate shell:
#
#   mix test test/bench/http_server_test.exs --include benchmark --trace
#
# Prints the real port it bound (config/runtime.exs's own `PORT` env var
# handling — unset by default — takes precedence over config/test.exs's
# compile-time 4002, so it actually ends up on 4000 unless PORT is set).
#
# Uses the exact same test-suite app bootstrap as every other test here
# (test/test_helper.exs already formed the shared, single-node-collapsed
# placement cluster by the time this test body runs) — the only override
# needed on top of that is forcing the endpoint to actually listen
# (config/test.exs sets `server: false`) and turning off the two dev-only
# conveniences that add real per-request overhead unrepresentative of a
# production build (the code-reloader plug checks file mtimes on every
# request; `debug_errors` renders a full stacktrace page on any exception).
# This is a `:test`-config build, not a full `:prod` release — `force_ssl`
# is compile-time-locked to `:prod` only (see config/prod.exs's own
# comment) and forming a real single-node placement cluster in `:prod`
# would need either real 3-ordinal DNS or a permanent runtime.exs escape
# hatch, neither of which is worth adding just for this. See the
# "Performance" section of the top-level README for the full methodology
# note and its stated caveats.
defmodule Riptide.Bench.HttpServer do
  use ExUnit.Case, async: false

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @tenant_id "http-bench-tenant"
  @read_path_segment "bench-read-doc"

  test "start a real HTTP server for external load-testing (wrk, curl, etc.)" do
    # `mix test` itself already started :riptide (with config/test.exs's
    # `server: false`) before this test's own code ever runs — Application.
    # ensure_all_started/1 below is a no-op against an already-started app,
    # and Phoenix's Endpoint only reads its config once, at its own
    # Supervisor's init — so changing config here has no effect until the
    # Endpoint child is actually restarted.
    existing_endpoint_config = Application.get_env(:riptide, RiptideWeb.Endpoint, [])

    Application.put_env(
      :riptide,
      RiptideWeb.Endpoint,
      Keyword.merge(existing_endpoint_config,
        server: true,
        code_reloader: false,
        debug_errors: false
      )
    )

    {:ok, _} = Application.ensure_all_started(:riptide)
    :ok = Supervisor.terminate_child(Riptide.Supervisor, RiptideWeb.Endpoint)
    {:ok, _pid} = Supervisor.restart_child(Riptide.Supervisor, RiptideWeb.Endpoint)

    :ok =
      Store.TenantFacts.add_policy(@tenant_id, [], %Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: :public
      })

    read_stream_id = ResourceController.stream_id_for({:tenant, @tenant_id}, [@read_path_segment])
    :ok = StreamSupervisor.ensure_ready(read_stream_id)

    # A representative small-to-medium resource body (10 triples) for the
    # read-path benchmark — big enough that Turtle encode/RDF.Graph fold
    # cost isn't zero, small enough to stay realistic for a single LDP
    # resource.
    graph =
      Enum.reduce(1..10, RDF.Graph.new(), fn n, acc ->
        RDF.Graph.add(
          acc,
          {RDF.iri("https://bench.example/s"), RDF.iri("https://bench.example/p#{n}"),
           "benchmark value #{n}"}
        )
      end)

    StreamServer.append(read_stream_id, Event.new(read_stream_id, :replace, graph))
    {:ok, put_body} = TurtleCodec.encode(graph)
    File.write!(Path.join(__DIR__, "put_body.ttl"), put_body)

    port = Application.get_env(:riptide, RiptideWeb.Endpoint)[:http][:port]

    IO.puts("""

    ================================================================
    Riptide HTTP benchmark server ready on http://127.0.0.1:#{port}
      GET  (read):  /tenants/#{@tenant_id}/resources/#{@read_path_segment}
      PUT  (write): /tenants/#{@tenant_id}/resources/<any-path> (body: test/bench/put_body.ttl)
      health probe: /health/live
    Anonymous access is allowed (a :public read+write policy was seeded for
    this tenant) — no Authorization header needed.
    Ctrl-C (twice) or `kill` this process to stop.
    ================================================================
    """)

    Process.sleep(:infinity)
  end
end
