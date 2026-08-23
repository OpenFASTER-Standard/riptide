defmodule Riptide.RaCluster do
  @moduledoc """
  The only module that calls into `:ra` directly. Every function here is
  verified against the pinned `:ra` version by `test/riptide/ra_cluster_test.exs`
  before any other module builds on top of it — if your pinned version's API
  differs from what's written here, this is the one place to fix it.
  """

  @system :default

  @spec server_id(String.t()) :: :ra.server_id()
  def server_id(stream_id) do
    {String.to_atom(uid_for(stream_id)), node()}
  end

  @spec uid_for(String.t()) :: binary()
  def uid_for(stream_id) do
    "riptide_" <> Base.encode16(:crypto.hash(:sha256, stream_id), case: :lower)
  end

  @spec start_or_restart(String.t(), :ra_machine.machine()) :: :ra.server_id()
  def start_or_restart(stream_id, machine) do
    ensure_system_started()
    server_id = server_id(stream_id)
    {name, _node} = server_id

    case :ra.restart_server(@system, server_id) do
      :ok ->
        server_id

      {:error, _reason} ->
        # `:ra.restart_server/2` fails with a variety of shapes here — a clean
        # `{:error, {:already_started, pid}}` if it notices the server is
        # already up, but also a `{:error, {:shutdown, {:failed_to_start_child,
        # Name, {:already_started, pid}}}}` when it loses a race against Ra's
        # *own* automatic restart of a crashed server (the per-server
        # `ra_server_sup` supervises its `ra_server_proc` worker with a
        # restart strategy that already brings a merely-crashed process back
        # up on its own — confirmed empirically: killing the server's pid and
        # immediately calling this function reliably hits this branch with
        # the process already alive again under the same name, well before
        # any explicit restart/start_cluster call could have run). Matching
        # every error shape `:ra` might use for "it's already running" is
        # fragile, so instead we check the one thing that actually matters:
        # is a process registered under this server's name right now?
        if server_alive?(name) do
          server_id
        else
          cluster_name = uid_for(stream_id) <> "_cluster"

          case :ra.start_cluster(@system, cluster_name, machine, [server_id]) do
            {:ok, [_server_id], []} ->
              server_id

            {:error, reason} ->
              if server_alive?(name) do
                server_id
              else
                raise "Failed to start or restart Ra server #{inspect(server_id)}: #{inspect(reason)}"
              end
          end
        end
    end
  end

  # NOTE: raising on `{:error, _}`/`{:timeout, _}` is deliberate for the
  # single-node Phase 1 cluster — at cluster size 1 there is no other replica
  # to fail over to, so a command that can't reach consensus is a genuine
  # local fault the caller should see. Once the Clustering/HA sub-project adds
  # multi-node membership, these paths need graceful handling/retry (e.g.
  # redirecting to the current leader on `{:error, {:redirect, _}}` or backing
  # off and retrying a transient `{:timeout, _}`) rather than raising.
  @spec process_command(:ra.server_id(), term()) :: term()
  def process_command(server_id, command) do
    case :ra.process_command(server_id, command) do
      {:ok, reply, _leader} -> reply
      {:error, reason} -> raise "Ra command failed for #{inspect(server_id)}: #{inspect(reason)}"
      {:timeout, _} -> raise "Ra command timed out for #{inspect(server_id)}"
    end
  end

  # A fast, *possibly stale* read of the local server's already-applied
  # machine state — reads deliberately skip consensus (see `RaMachine`'s
  # moduledoc). Right after a server restart the recovered process holds its
  # full durable log on disk but re-applies it asynchronously, so a
  # `local_query` can briefly observe a not-yet-fully-caught-up state. Use
  # `consistent_query/2` when you need a linearizable read that reflects
  # everything committed so far (e.g. asserting durability right after a
  # crash-restart). Same single-node error-handling caveat as
  # `process_command/2` above applies.
  @spec local_query(:ra.server_id(), (term() -> term())) :: term()
  def local_query(server_id, query_fun) do
    case :ra.local_query(server_id, query_fun) do
      {:ok, {_index_term, result}, _leader} -> result
      {:error, reason} -> raise "Ra query failed for #{inspect(server_id)}: #{inspect(reason)}"
      {:timeout, _} -> raise "Ra query timed out for #{inspect(server_id)}"
    end
  end

  # Linearizable read: unlike `local_query/2` this goes through the leader and,
  # by Raft's definition, only answers after the server has applied everything
  # committed as of the query — so it deterministically observes the fully
  # recovered log even immediately after a restart. Reply shape is
  # `{:ok, Reply, Leader}` (no index/term wrapper, unlike `local_query`).
  @spec consistent_query(:ra.server_id(), (term() -> term())) :: term()
  def consistent_query(server_id, query_fun) do
    case :ra.consistent_query(server_id, query_fun) do
      {:ok, result, _leader} ->
        result

      {:error, reason} ->
        raise "Ra consistent query failed for #{inspect(server_id)}: #{inspect(reason)}"

      {:timeout, _} ->
        raise "Ra consistent query timed out for #{inspect(server_id)}"
    end
  end

  @spec force_delete(String.t()) :: :ok
  def force_delete(stream_id) do
    ensure_system_started()
    server_id = server_id(stream_id)
    _ = :ra.force_delete_server(@system, server_id)
    :ok
  end

  # Starting the `:ra` OTP application (which happens automatically as a
  # regular dependency of `:riptide`) does NOT start the `:default` Ra
  # system that `server_id/1`'s `@system` refers to — `ra_sup`'s supervision
  # tree only brings up `ra_systems_sup`, an *empty* supervisor for
  # dynamically-started systems. Every consuming application is expected to
  # explicitly start (or restart) its Ra system(s) itself; see `ra`'s own
  # README ("ra:start/0") and `ra_system:start_default/0`. We do it lazily
  # and idempotently here, rather than in `Riptide.Application.start/2`, so
  # `RaCluster` remains the sole module that talks to `:ra` at all and every
  # entry point that needs the system stays self-sufficient.
  @spec ensure_system_started() :: :ok
  defp ensure_system_started do
    case :ra_system.start_default() do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Failed to start the default Ra system: #{inspect(reason)}"
    end
  end

  @spec server_alive?(atom()) :: boolean()
  defp server_alive?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
