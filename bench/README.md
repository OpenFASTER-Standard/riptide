# Benchmarks

Supporting files for the "Performance" section of the top-level `README.md`. The actual runnable
scripts live under `test/bench/` (not here) as real `ExUnit.Case` modules, so they can reuse
`test/test_helper.exs`'s already-proven app/Ra-cluster bootstrap — `mix run`'s own boot sequence
starts `:riptide` before a plain script's top-level code even runs, which breaks the
single-node-collapsed placement cluster these benchmarks depend on. Both are tagged `:benchmark`,
which `test/test_helper.exs` excludes by default, so a normal `mix test`/CI run never executes
either one (one is a multi-second Benchee run, the other blocks forever on purpose) — run them
explicitly with `--include benchmark`:

- `test/bench/core_bench_test.exs` — Elixir-level `Benchee` micro-benchmarks for
  `Riptide.RDF.TurtleCodec`, `Riptide.Stream.StreamServer.append/2`/`get_since/2`,
  `Riptide.Placement.lookup/1`, and `Riptide.Authz.evaluate/4`:

  ```bash
  mix test test/bench/core_bench_test.exs --include benchmark --trace
  ```

- `test/bench/http_server_test.exs` — boots a real, single-node Riptide instance with a live HTTP
  listener (config/test.exs's own `server: false` overridden, dev-only `code_reloader`/
  `debug_errors` explicitly disabled) for external load-testing, seeding one `:public`
  `[:read, :write]` policy and one pre-existing resource for the read benchmarks:

  ```bash
  mix test test/bench/http_server_test.exs --include benchmark --trace
  ```

  Never exits on its own — stop it with Ctrl-C/`kill` when done. Drive it from a separate shell,
  e.g. with `wrk`:

  ```bash
  wrk -t8 -c128 -d10s --latency http://127.0.0.1:4000/tenants/http-bench-tenant/resources/bench-read-doc
  wrk -t8 -c128 -d10s --latency -s bench/wrk-put.lua http://127.0.0.1:4000/tenants/http-bench-tenant/resources/put-bench-doc
  wrk -t8 -c128 -d10s --latency -s bench/wrk-put-many-resources.lua http://127.0.0.1:4000
  ```

This directory holds only the two `wrk` Lua scripts those last two commands reference:

- `wrk-put.lua` — `PUT`s the same fixed resource path on every request (tests the single-writer
  Ra log serialization one specific resource is subject to).
- `wrk-put-many-resources.lua` — round-robins `PUT`s across 500 different resource paths (tests
  Riptide's actual per-resource write parallelism — the realistic multi-resource shape). Run a
  short warm-up pass first if you want steady-state numbers that exclude first-write
  stream-creation cost for each of the 500 paths — see the top-level README's own "Methodology"
  subsection for why and how.
