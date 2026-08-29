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

  @doc """
  Requests a restart of the process registered under `id`: honored only
  if `session_active?/1` reports the process idle, in which case it exits
  abnormally (`:restart_requested` — not `:normal`/`:shutdown`), and
  `:transient` brings a fresh instance back up under the same `id`
  automatically. Refused (`{:error, :session_active}`) if a session is
  active — the caller decides whether/when to retry; no internal queue.
  """
  @spec request_restart(term()) :: :ok | {:error, :session_active} | {:error, :not_found}
  def request_restart(id), do: control(id, :restart_requested)

  @doc """
  Like `request_restart/1`, but exits `:normal` when honored — `:transient`
  does not restart on a `:normal` exit, so the process is gone for good.
  """
  @spec request_revoke(term()) :: :ok | {:error, :session_active} | {:error, :not_found}
  def request_revoke(id), do: control(id, :normal)

  @doc """
  Shared helper a consumer's own `handle_call` clause delegates to,
  keeping the session-active check inside the target process's own
  serialized mailbox — atomic with respect to any other message that
  process might be handling, closing the race an outside-the-mailbox
  check (e.g. `:sys.get_state/1` then a separate stop call) would have
  (design spec §2).
  """
  @spec handle_stop_if_idle(module(), term(), term(), GenServer.from()) ::
          {:reply, {:error, :session_active}, term()} | {:stop, term(), term()}
  def handle_stop_if_idle(module, state, reason, from) do
    if module.session_active?(state) do
      {:reply, {:error, :session_active}, state}
    else
      GenServer.reply(from, :ok)
      {:stop, reason, state}
    end
  end

  defp control(id, reason) do
    case Registry.lookup(@registry, id) do
      [{pid, _module}] -> GenServer.call(pid, {:riptide_supervised_process, :stop_if_idle, reason})
      [] -> {:error, :not_found}
    end
  end
end
