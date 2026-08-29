defmodule Riptide.SupervisedProcess do
  @moduledoc """
  A reusable supervised long-running process primitive, typed for the
  revocable/restartable adaptation-safety property from session types
  with runtime adaptation (Di Giusto & Pérez, arXiv:1312.2699). See
  design spec
  `docs/superpowers/specs/2026-08-29-phase-6b-ii-supervised-process-design.md`.

  A consumer implements `@behaviour Riptide.SupervisedProcess` (just
  `session_active?/1`), a normal `init/1`, and one boilerplate
  `handle_call` clause forwarding to `handle_stop_if_idle/4` — no
  `start_link/2` of its own; `start/3` calls `GenServer.start_link/3`
  directly, registering the process via a 4-tuple `:via` name so a later
  lookup also recovers which module's `session_active?/1` to call.
  """

  @callback session_active?(state :: term()) :: boolean()

  @registry Riptide.SupervisedProcess.Registry
  @dynamic_supervisor Riptide.SupervisedProcess.DynamicSupervisor

  @doc """
  Starts `module` (implementing `init/1` and this behaviour) under the
  shared `DynamicSupervisor`, registered under `id` for later
  `request_restart/1`/`request_revoke/1` lookups. Every managed process
  uses `restart: :transient` uniformly (design spec §2) — restarted on
  abnormal exit (a real crash, or `request_restart/1`), not restarted on
  `:normal` exit (`request_revoke/1`).
  """
  @spec start(term(), module(), term()) :: {:ok, pid()} | {:error, term()}
  def start(id, module, init_arg) do
    via = {:via, Registry, {@registry, id, module}}

    child_spec = %{
      id: id,
      start: {GenServer, :start_link, [module, init_arg, [name: via]]},
      restart: :transient
    }

    DynamicSupervisor.start_child(@dynamic_supervisor, child_spec)
  end
end
