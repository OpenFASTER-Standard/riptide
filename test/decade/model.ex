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
  """

  use PropCheck
  use PropCheck.StateM

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.RDF.TurtleCodec

  @endpoint_opts RiptideWeb.Endpoint.init([])

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
      {3,
       {:call, __MODULE__, :patch_resource,
        [oneof(state.tenants), path_gen(), triple_gen(), triple_gen()]}},
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
    :put
    |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}", triple)
    |> Plug.Conn.put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@endpoint_opts)
    |> Map.fetch!(:status)
  end

  @doc false
  @spec patch_resource(String.t(), String.t(), String.t(), String.t()) :: integer()
  def patch_resource(tenant_id, path, addition, removal) do
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
    :delete
    |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}")
    |> RiptideWeb.Endpoint.call(@endpoint_opts)
    |> Map.fetch!(:status)
  end
end
