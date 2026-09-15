defmodule Riptide.Decade.Model do
  @moduledoc """
  A `PropCheck.StateM` reference model for Riptide's LDP resource
  semantics: PUT/PATCH/DELETE and tenant creation, generated in long
  random sequences and checked against the real HTTP surface
  (`Plug.Test.conn/2` + `RiptideWeb.Endpoint.call/2` — the same in-process
  pattern `test/riptide_web/ldp/resource_controller_test.exs` already
  uses; not a live TCP listener) after every step.

  Model state tracks, per `{tenant_id, path}`, the set of raw Turtle
  triple-lines that were written (via PUT/PATCH) and not since overwritten
  or deleted. Real GET responses are parsed back into `RDF.Graph` triples
  (via `Riptide.RDF.TurtleCodec.decode/1`, the exact same codec the product
  uses) and compared against the *parsed* form of the expected lines —
  **not** compared as raw text. `RDF.Turtle.write_string/1` pretty-prints
  multi-predicate-same-subject resources using `;`-grouped syntax spanning
  multiple lines (confirmed empirically: a resource with 2 triples sharing
  a subject serializes as one `<s>` line followed by two indented
  `<p> <o> ;`/`<p> <o> .` lines, plus a leading `@prefix` block for any
  non-empty graph), so a naive "split on newline, compare raw lines"
  comparison — the plan's original sketch — would spuriously fail the
  moment a resource accumulates more than one triple. Comparing parsed
  triple sets instead is format-independent and still a genuine,
  non-vacuous check of real product behavior.

  There is no `change_retention` command: `Riptide.Stream.StreamServer`
  only applies `retention` when a stream is first created, and every
  normal write path already hardcodes `:infinity` — there is no live
  retention-mutation operation in this codebase to model.

  ## Stream cleanup

  Every command here creates a real, disk-persisted Ra cluster plus a
  permanent BEAM atom (`test/support/ra_test_helpers.ex`'s moduledoc:
  "Every test that starts a stream through `StreamServer`/`StreamSupervisor`
  must call [`Riptide.RaTestHelpers.cleanup_stream/1`] in `on_exit/1`") —
  `create_tenant/0` via `Store.TenantFacts.add_policy/3` (writes to the
  tenant's `_authz/policies` stream), and `put_resource/3`/`patch_resource/4`/
  `delete_resource/2` via the HTTP controller's own
  `StreamSupervisor.ensure_ready/1` call (all three, including `delete`,
  mint the cluster/atom even for a path that was never written before —
  only `GET`'s read path avoids this, per `ResourceController`'s own
  atom-exhaustion-guard comments). Since `PropCheck.StateM`'s `next_state/3`
  runs at *generation* time too — when `tenant_id` can still be an
  unresolved symbolic `{:var, N}` term, not yet a real string — stream ids
  can't be computed there (string-interpolating a symbolic var would
  crash). Instead, each command-execution function below records the real
  stream_id it touches into the *calling test process's* process
  dictionary (`:proper_statem.run_commands/2` executes every command
  synchronously in the caller's own process, not a spawned one, so this is
  safe and simple) via `record_stream_id!/1`. `drain_stream_ids/0` lets the
  property test read back and clear everything touched by one
  `run_commands/2` call, then clean each one up — capturing every stream a
  run genuinely created, including ones touched by a command whose
  postcondition then failed (the real HTTP write already happened even
  though the check afterward didn't pass), which relying on the model's
  own returned `state` alone would miss.
  """

  use PropCheck
  use PropCheck.StateM

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.RDF.TurtleCodec
  alias RiptideWeb.LDP.ResourceController

  @endpoint_opts RiptideWeb.Endpoint.init([])
  @stream_ids_pdict_key :riptide_decade_model_stream_ids

  @impl true
  def initial_state, do: %{tenants: [], resources: %{}}

  @impl true
  def command(%{tenants: []}) do
    {:call, __MODULE__, :create_tenant, []}
  end

  def command(state) do
    frequency([
      {1, {:call, __MODULE__, :create_tenant, []}},
      {5, {:call, __MODULE__, :put_resource, [oneof(state.tenants), path_gen(), triple_gen()]}},
      {3, patch_resource_call(state)},
      {2, {:call, __MODULE__, :delete_resource, [oneof(state.tenants), path_gen()]}}
    ])
  end

  defp path_gen do
    let n <- integer(1, 20) do
      "decade-res-#{n}"
    end
  end

  defp triple_gen do
    let {p, o} <- {oneof(["p1", "p2", "p3"]), integer(1, 1_000)} do
      "<https://decade.example/s> <https://decade.example/#{p}> \"#{o}\" .\n"
    end
  end

  # `triple_gen/0` alone draws from a fixed subject x 3 predicates x 1000
  # objects (3,000 possible triples). Drawing `addition` and `removal`
  # independently from it (the plan's original sketch) means `removal`
  # matches something actually tracked for `{tenant_id, path}` (at most 3
  # triples there) only ~0.1% of the time — PATCH's removal-half of
  # "additive delta" (the specific behavior the design spec calls out)
  # would then almost never be meaningfully exercised; `MapSet.delete/2`
  # and the real `RDF.Graph.delete/2` underneath it would almost always be
  # no-ops. Fixed here by choosing `tenant_id`/`path` first (an explicit
  # `let`, since the removal generator built from them needs their
  # concrete generated values, not just their own generators — plain
  # generator-as-tuple-element juxtaposition, as `put_resource`'s args
  # above use, can't express that dependency), then looking up what the
  # model already tracks for that exact key and weighting removal 3:1
  # toward picking one of those known triples over a fully independent
  # random one — still leaving a real (1-in-4) chance of exercising
  # "remove something that isn't there", and falling back to fully random
  # when nothing is tracked yet (nothing to correlate against).
  defp patch_resource_call(state) do
    let {tenant_id, path} <- {oneof(state.tenants), path_gen()} do
      let {addition, removal} <- {triple_gen(), removal_gen(state, tenant_id, path)} do
        {:call, __MODULE__, :patch_resource, [tenant_id, path, addition, removal]}
      end
    end
  end

  defp removal_gen(state, tenant_id, path) do
    case state.resources |> Map.get({tenant_id, path}, MapSet.new()) |> MapSet.to_list() do
      [] -> triple_gen()
      existing -> frequency([{3, oneof(existing)}, {1, triple_gen()}])
    end
  end

  @impl true
  def precondition(_state, _call), do: true

  @impl true
  def next_state(state, tenant_id, {:call, __MODULE__, :create_tenant, []}) do
    %{state | tenants: [tenant_id | state.tenants]}
  end

  def next_state(state, _result, {:call, __MODULE__, :put_resource, [tenant_id, path, triple]}) do
    put_in(state, [:resources, {tenant_id, path}], MapSet.new([triple]))
  end

  def next_state(
        state,
        _result,
        {:call, __MODULE__, :patch_resource, [tenant_id, path, addition, removal]}
      ) do
    current = Map.get(state.resources, {tenant_id, path}, MapSet.new())
    updated = current |> MapSet.delete(removal) |> MapSet.put(addition)
    put_in(state, [:resources, {tenant_id, path}], updated)
  end

  def next_state(
        state,
        _result,
        {:call, __MODULE__, :delete_resource, [tenant_id, path]}
      ) do
    %{state | resources: Map.delete(state.resources, {tenant_id, path})}
  end

  @impl true
  def postcondition(_state, {:call, __MODULE__, :create_tenant, []}, tenant_id) do
    is_binary(tenant_id)
  end

  def postcondition(_state, {:call, __MODULE__, :put_resource, [tenant_id, path, triple]}, status) do
    status == 201 and
      current_triples(tenant_id, path) == expected_triples(MapSet.new([triple]))
  end

  def postcondition(
        state,
        {:call, __MODULE__, :patch_resource, [tenant_id, path, addition, removal]},
        status
      ) do
    expected =
      state.resources
      |> Map.get({tenant_id, path}, MapSet.new())
      |> MapSet.delete(removal)
      |> MapSet.put(addition)

    status == 200 and current_triples(tenant_id, path) == expected_triples(expected)
  end

  def postcondition(_state, {:call, __MODULE__, :delete_resource, [tenant_id, path]}, status) do
    status == 204 and current_triples(tenant_id, path) == MapSet.new()
  end

  # Parses each raw Turtle triple-line the model has been tracking into its
  # canonical `RDF.Graph` triple form, via the same codec the product uses,
  # so comparison against `current_triples/2` is format-independent (see
  # moduledoc).
  @spec expected_triples(MapSet.t(String.t())) :: MapSet.t(RDF.Triple.t())
  defp expected_triples(turtle_lines) do
    turtle_lines
    |> Enum.flat_map(fn line ->
      {:ok, graph} = TurtleCodec.decode(line)
      RDF.Graph.triples(graph)
    end)
    |> MapSet.new()
  end

  @spec current_triples(String.t(), String.t()) :: MapSet.t(RDF.Triple.t())
  defp current_triples(tenant_id, path) do
    conn =
      :get
      |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}")
      |> RiptideWeb.Endpoint.call(@endpoint_opts)

    case conn.status do
      404 ->
        MapSet.new()

      200 ->
        {:ok, graph} = TurtleCodec.decode(conn.resp_body)
        graph |> RDF.Graph.triples() |> MapSet.new()
    end
  end

  @doc false
  @spec create_tenant() :: String.t()
  def create_tenant do
    tenant_id = Uniq.UUID.uuid4()

    record_stream_id!(
      ResourceController.stream_id_for({:tenant, tenant_id}, ["_authz", "policies"])
    )

    :ok =
      Store.TenantFacts.add_policy(tenant_id, [], %Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: :public
      })

    tenant_id
  end

  @doc false
  @spec put_resource(String.t(), String.t(), String.t()) :: integer()
  def put_resource(tenant_id, path, triple) do
    record_stream_id!(ResourceController.stream_id_for({:tenant, tenant_id}, [path]))

    :put
    |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}", triple)
    |> Plug.Conn.put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@endpoint_opts)
    |> Map.fetch!(:status)
  end

  @doc false
  @spec patch_resource(String.t(), String.t(), String.t(), String.t()) :: integer()
  def patch_resource(tenant_id, path, addition, removal) do
    record_stream_id!(ResourceController.stream_id_for({:tenant, tenant_id}, [path]))
    body = Jason.encode!(%{"additions" => addition, "removals" => removal})

    :patch
    |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> RiptideWeb.Endpoint.call(@endpoint_opts)
    |> Map.fetch!(:status)
  end

  @doc false
  @spec delete_resource(String.t(), String.t()) :: integer()
  def delete_resource(tenant_id, path) do
    record_stream_id!(ResourceController.stream_id_for({:tenant, tenant_id}, [path]))

    :delete
    |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}")
    |> RiptideWeb.Endpoint.call(@endpoint_opts)
    |> Map.fetch!(:status)
  end

  # Records a stream_id a just-executed command touched, into the calling
  # test process's own process dictionary (see moduledoc's "Stream
  # cleanup" section for why here, not in `next_state/3`). Recording
  # unconditionally, before the real HTTP/store call, is deliberately
  # over-inclusive rather than under: `Riptide.RaCluster.force_delete/1`
  # (what `Riptide.RaTestHelpers.cleanup_stream/1` calls) is a no-op — its
  # `:ra.force_delete_server/2` result is discarded — for a stream_id that
  # was never actually created, so cleaning up a stream_id whose write
  # attempt failed costs nothing.
  @spec record_stream_id!(String.t()) :: :ok
  defp record_stream_id!(stream_id) do
    Process.put(@stream_ids_pdict_key, [stream_id | Process.get(@stream_ids_pdict_key, [])])
    :ok
  end

  @doc """
  Returns every stream_id recorded by commands executed (via
  `record_stream_id!/1`) since the last `drain_stream_ids/0` call on this
  process, and resets the record to empty. Meant to be called once per
  `run_commands/2` call, in the property test body, right after
  `run_commands/2` returns — `:proper_statem.run_commands/2` executes
  every command synchronously in the calling process, so this reliably
  captures every stream that one run touched, regardless of whether the
  run completed cleanly or stopped early on a failing postcondition.
  """
  @spec drain_stream_ids() :: [String.t()]
  def drain_stream_ids do
    ids = Process.get(@stream_ids_pdict_key, [])
    Process.delete(@stream_ids_pdict_key)
    ids
  end
end
