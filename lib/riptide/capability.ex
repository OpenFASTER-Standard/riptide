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
    Riptide.Authz.evaluate(tenant_id, path, current_subject, :invoke) == :allow
  end

  defp local_name(%Definition{name: name}) do
    name |> RDF.IRI.to_string() |> String.trim_leading(@capability_ns)
  end
end
