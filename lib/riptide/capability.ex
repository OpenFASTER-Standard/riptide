defmodule Riptide.Capability do
  @moduledoc """
  Authorizes and invokes a tenant-scoped WASI Preview 2 Capability. See
  design spec
  `docs/superpowers/specs/2026-08-28-phase-6b-i-wasi-execution-substrate-design.md`
  (Revision 2). Invocation (`invoke/4`) shells out to the `wasmtime` CLI as
  a separate OS process rather than any in-process WASM host — Revision 2
  documents why (`wasmex`'s Components API cannot bound execution time at
  all, proven empirically during design).
  """

  alias Riptide.Capability.Definition

  @capability_ns "urn:riptide:capability:"

  @doc """
  Whether `current_subject` may invoke `definition` in `tenant_id`, per the
  existing ACP authorization surface (`Riptide.Authz.evaluate/4`) — a
  Capability is addressed as the synthetic path `["capabilities",
  local_name]`, reusing default-deny/container-inheritance/deny-overrides
  with zero new authorization logic.
  """
  @spec authorized?(Definition.t(), String.t(), map() | nil) :: boolean()
  def authorized?(%Definition{} = definition, tenant_id, current_subject) do
    path = ["capabilities", local_name(definition)]
    Riptide.Authz.evaluate({:tenant, tenant_id}, path, current_subject, :invoke) == :allow
  end

  defp local_name(%Definition{name: name}) do
    name |> RDF.IRI.to_string() |> String.trim_leading(@capability_ns)
  end

  @memory_limit_flags %{
    max_memory_size: "max-memory-size",
    max_table_elements: "max-table-elements",
    max_instances: "max-instances",
    max_tables: "max-tables"
  }

  @doc """
  Invokes `definition.function` inside `definition.component` with `args`,
  as `current_subject` in `tenant_id` — checking `authorized?/3` first and
  returning `{:error, :unauthorized}` without spawning any process at all
  if it fails. Runs via the `wasmtime` CLI as a separate OS process (see
  moduledoc) rather than any in-process WASM host.
  """
  @spec invoke(Definition.t(), String.t(), map() | nil, [String.t()]) ::
          {:ok, String.t()} | {:error, :unauthorized | :resource_exhausted | {:trap, String.t()}}
  def invoke(%Definition{} = definition, tenant_id, current_subject, args) do
    if authorized?(definition, tenant_id, current_subject) do
      run_wasmtime(definition, args)
    else
      {:error, :unauthorized}
    end
  end

  defp run_wasmtime(%Definition{} = definition, args) do
    cli_args =
      [
        "run",
        "-W",
        "component-model=y",
        "-W",
        "fuel=#{definition.fuel_limit}",
        "-W",
        "timeout=#{definition.timeout_ms}ms"
      ] ++
        memory_limit_flags(definition.memory_limits) ++
        [
          "-S",
          "inherit-stdin=n",
          "-S",
          "inherit-stdout=n",
          "-S",
          "inherit-stderr=n",
          "-S",
          "inherit-network=n"
        ] ++
        ["--invoke", invoke_expr(definition, args), definition.component]

    {output, exit_status} = System.cmd("wasmtime", cli_args, stderr_to_stdout: true)
    classify_result(exit_status, output)
  end

  defp memory_limit_flags(memory_limits) do
    Enum.flat_map(@memory_limit_flags, fn {key, flag_name} ->
      case Map.fetch!(memory_limits, key) do
        nil -> []
        value -> ["-W", "#{flag_name}=#{value}"]
      end
    end)
  end

  defp invoke_expr(%Definition{function: function}, args) do
    encoded_args = Enum.map_join(args, ", ", &inspect/1)
    "#{function}(#{encoded_args})"
  end

  defp classify_result(0, output), do: {:ok, String.trim(output)}

  defp classify_result(_exit_status, output) do
    cond do
      String.contains?(output, "all fuel consumed") -> {:error, :resource_exhausted}
      String.contains?(output, "interrupt") -> {:error, :resource_exhausted}
      String.contains?(output, "exceeds memory limits") -> {:error, :resource_exhausted}
      true -> {:error, {:trap, output}}
    end
  end
end
