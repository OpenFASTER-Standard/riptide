defmodule Riptide.RaCluster do
  @moduledoc """
  The only module that calls into `:ra` directly. Every function here is
  verified against the pinned `:ra` version by `test/riptide/ra_cluster_test.exs`
  before any other module builds on top of it — if your pinned version's API
  differs from what's written here, this is the one place to fix it.
  """

  require Logger

  @system :default

  @spec server_id(String.t()) :: :ra.server_id()
  def server_id(stream_id) do
    {String.to_atom(uid_for(stream_id)), node()}
  end

  @spec uid_for(String.t()) :: binary()
  def uid_for(stream_id) do
    "riptide_" <> Base.encode16(:crypto.hash(:sha256, stream_id), case: :lower)
  end

  @placement_cluster_name :riptide_placement
  @placement_uid "riptide_placement"

  @spec placement_server_id(node()) :: :ra.server_id()
  def placement_server_id(node), do: {@placement_cluster_name, node}

  # Whether THIS node is currently the placement cluster's Raft leader —
  # used by `Riptide.Stream.ReplicaHealer` (Phase 3d-ii) to gate stream
  # replica repair so only one of the 3 placement ordinals ever acts on a
  # given sweep, reusing the placement cluster's own existing leader
  # election rather than a new coordination mechanism. Queries the LOCAL
  # member directly (`{@placement_cluster_name, node()}`) rather than going
  # through `placement_server_id/2`'s ordinal/DNS resolution, since this is
  # only ever meaningful to call from a node that's itself a placement
  # ordinal already running its own local member.
  # Wrapped in `try/catch :exit` because `:ra.members/1` doesn't always turn
  # a bad outcome into an `{:error, _}` tuple: `ra_server_proc`'s own
  # `gen_statem_safe_call/3` only converts `timeout`/`noproc`/`nodedown`/
  # `shutdown` exits into a return value — any OTHER exit (e.g. the local
  # member process crashing for an unrelated reason while this exact call is
  # in flight) propagates straight out of `gen_statem:call/3` as a genuine
  # `exit`, which a plain `case` can't catch. `Riptide.Stream.ReplicaHealer`
  # (Phase 3d-ii) is the first caller to invoke this from a periodic
  # boot-time timer rather than a one-off request path, so a rare exit here
  # would otherwise crash that GenServer outright instead of just skipping a
  # sweep. Any exit is treated as "not the leader" — the same conservative
  # default this function already returns for a plain `{:error, _}`.
  @spec placement_leader?() :: boolean()
  def placement_leader? do
    case :ra.members({@placement_cluster_name, node()}) do
      {:ok, _members, {@placement_cluster_name, leader_node}} -> leader_node == node()
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @spec start_or_restart(String.t(), :ra_machine.machine()) :: :ra.server_id()
  def start_or_restart(stream_id, machine) do
    ensure_system_started()
    server_id = server_id(stream_id)
    {name, _node} = server_id

    # Fast path: a process is already registered and alive under this
    # server's deterministic name — nothing to (re)start. This only ever
    # matters for a live-in-this-BEAM race (e.g. Ra's own `ra_server_sup`
    # restart strategy already brought a merely-crashed process back up
    # before this function got a chance to run), never for a genuine cold
    # restart (a fresh BEAM VM starts with no such process registered).
    if server_alive?(name) do
      server_id
    else
      start_new_cluster(server_id, name, stream_id, machine)
    end
  end

  # `:ra.start_cluster/2`, unlike `:ra.start_server/2`, also triggers a
  # leader election after starting the local server — required for a
  # genuinely brand-new server (one with no prior Raft term/log on disk),
  # which otherwise sits idle waiting for a leader's heartbeat forever
  # (confirmed empirically: `:ra.start_server/2` alone never became ready,
  # even after 10s, for a fresh uid). Passing our own already-computed
  # deterministic `uid` (rather than letting `:ra` mint a random one, as the
  # old `start_fresh_cluster/4` did via the legacy `:ra.start_cluster/4`
  # API) is what makes this idempotent: calling it again for the same
  # `stream_id` — whether because the local process just isn't running yet,
  # or because a real crash left `:ra`'s DETS-backed server registry with no
  # memory of it at all — always resolves to the same on-disk directory and
  # recovers whatever was durably written there, rather than silently
  # minting a fresh empty log under a new identity.
  defp start_new_cluster(server_id, name, stream_id, machine) do
    uid = uid_for(stream_id)

    config = %{
      id: server_id,
      uid: uid,
      cluster_name: uid <> "_cluster",
      log_init_args: %{uid: uid},
      initial_members: [server_id],
      machine: machine
    }

    case :ra.start_cluster(@system, [config]) do
      {:ok, [^server_id], []} ->
        server_id

      {:error, {:already_started, _pid}} ->
        server_id

      {:error, reason} ->
        # Loses the same race the fast-path check in `start_or_restart/2`
        # guards against, just later: `ra_server_sup`'s own restart strategy
        # can bring the crashed process back up under this name in the gap
        # between that check and this call, making `:ra.start_server/2`
        # (called internally, per member, by `:ra.start_cluster/2`) return
        # `{:error, {:already_started, pid}}` for our one-and-only member —
        # which `:ra.start_cluster/2` then reports as the group-level
        # `{:error, :cluster_not_formed}` seen here, since it only treats a
        # bare `:ok` as a successful member start. Confirmed flaky without
        # this recheck: `mix test` run 5x in a row surfaced it in 3/5 runs,
        # always in a test that kills a live server's pid and immediately
        # calls `start_or_restart/2` again. Give the racing restart one
        # last chance to have already won before giving up.
        if server_alive?(name) do
          server_id
        else
          raise "Failed to start or restart Ra server #{inspect(server_id)}: #{inspect(reason)}"
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
  # Wrapped in `catch :exit` for the same reason `placement_leader?/0` and
  # `member_alive?/1` already are (see their own docs): `gen_statem_safe_call/3`
  # only converts `timeout`/`noproc`/`nodedown`/`shutdown` exits into a
  # return value this `case` can match — any OTHER exit (e.g. the target
  # `ra_server_proc` crashing for an unrelated reason mid-call) propagates as
  # a raw `exit` a plain `case` can't catch, which previously meant callers
  # relying on "this function always raises, never exits" (e.g.
  # `Riptide.Placement.with_current_members/1`'s `rescue`-based member
  # fallback) could still crash outright on that one failure class. Uniformly
  # `raise`ing here — whether the underlying failure came back as an
  # `{:error, _}`/`{:timeout, _}` tuple or a raw `exit` — restores that
  # "always raises" contract for every caller.
  @spec process_command(:ra.server_id(), term()) :: term()
  def process_command(server_id, command) do
    case :ra.process_command(server_id, command) do
      {:ok, reply, _leader} -> reply
      {:error, reason} -> raise "Ra command failed for #{inspect(server_id)}: #{inspect(reason)}"
      {:timeout, _} -> raise "Ra command timed out for #{inspect(server_id)}"
    end
  catch
    :exit, reason -> raise "Ra command exited for #{inspect(server_id)}: #{inspect(reason)}"
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
  # See `process_command/2`'s own `catch :exit` for why this is needed.
  @spec local_query(:ra.server_id(), (term() -> term())) :: term()
  def local_query(server_id, query_fun) do
    case :ra.local_query(server_id, query_fun) do
      {:ok, {_index_term, result}, _leader} -> result
      {:error, reason} -> raise "Ra query failed for #{inspect(server_id)}: #{inspect(reason)}"
      {:timeout, _} -> raise "Ra query timed out for #{inspect(server_id)}"
    end
  catch
    :exit, reason -> raise "Ra query exited for #{inspect(server_id)}: #{inspect(reason)}"
  end

  # Linearizable read: unlike `local_query/2` this goes through the leader and,
  # by Raft's definition, only answers after the server has applied everything
  # committed as of the query — so it deterministically observes the fully
  # recovered log even immediately after a restart. Reply shape is
  # `{:ok, Reply, Leader}` (no index/term wrapper, unlike `local_query`).
  # See `process_command/2`'s own `catch :exit` for why this is needed.
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
  catch
    :exit, reason ->
      raise "Ra consistent query exited for #{inspect(server_id)}: #{inspect(reason)}"
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
  # README ("ra:start/0") and `ra_system:start_default/0`. Idempotent, so
  # every entry point that needs the system stays self-sufficient by calling
  # this lazily — but ALSO called unconditionally and synchronously from
  # `Riptide.Application.start/2` for every fleet node (not just the 3
  # placement ordinals), closing the startup race where a node picked as a
  # brand-new stream's replica hadn't started its own local system yet by
  # the time a sibling's `:ra.start_cluster/2` call tried to reach it over
  # RPC (see Phase 3d-i HA-proof spike, finding 1).
  @spec ensure_system_started() :: :ok
  def ensure_system_started do
    config = system_config()

    case :ra_system.start(config) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Failed to start the default Ra system: #{inspect(reason)}"
    end
  end

  # Every caller that starts (or restarts) the `:default` Ra system MUST build
  # this exact config, byte-for-byte — not just "a config pointing at the same
  # directory". `ra_systems_sup:start_system/1` calls `ra_system:store/1`
  # unconditionally, even on the losing side of an `{:already_started, _}`
  # race, which persists whatever config *that* caller passed into
  # `persistent_term` regardless of which caller actually won the underlying
  # supervisor start. Two callers racing to start `:default` with
  # merely-equivalent-but-not-identical configs can therefore leave
  # `:ra_system.fetch(:default)` permanently reporting a config decoupled from
  # wherever the system's data (and its DETS-backed server registry) actually
  # live on disk — this was a real, confirmed-flaky bug before all call sites
  # (production and the two tests that manually restart `:default`) were
  # switched to share this single function. Ensures the target directory
  # exists as a side effect, matching what every call site needs immediately
  # before calling `:ra_system.start/1`.
  @spec system_config() :: map()
  def system_config do
    dir = data_dir()
    File.mkdir_p!(dir)

    :ra_system.default_config()
    |> Map.put(:data_dir, dir)
    |> Map.put(:wal_data_dir, dir)
  end

  # Stable across pod restarts/rescheduling even though Erlang distribution identity
  # (node()) is now IP-based and NOT stable — see Phase 3b design spec §1/§3.
  # Kubernetes sets a StatefulSet pod's HOSTNAME to its stable pod name (e.g.
  # "riptide-0"); outside Kubernetes (local dev, docker-compose, tests) HOSTNAME
  # still resolves to something stable per-container/per-host, so this doesn't
  # regress non-clustered environments. Both `data_dir` and `wal_data_dir` are
  # pinned here — `:ra`'s own `default_config/0` would otherwise leave
  # `wal_data_dir` defaulted to the OLD node()-derived directory
  # (`ra_system.erl`'s `WalDataDir = application:get_env(ra, wal_data_dir,
  # DataDir)`), silently splitting a stream's WAL from the rest of its data
  # across two different, inconsistently-keyed directories.
  #
  # `to_string/1` on the configured base handles both shapes `:ra, :data_dir`
  # can arrive in: a plain binary (the `File.cwd!()` fallback) or a charlist
  # (config/runtime.exs stores `RIPTIDE_RA_DATA_DIR` as a charlist, since it's
  # passed straight into Erlang code that expects `file:filename()`) — `Path.join/2`
  # raises on a charlist, unlike Erlang's more permissive `filename:join/2`.
  #
  # Returns a charlist, not a `String.t()` binary, despite the `String.t()`
  # produced by `Path.join/2` being the more idiomatic Elixir shape: `:ra`'s
  # own config typespec declares `data_dir`/`wal_data_dir` as `file:filename()`
  # (an Erlang charlist), and — critically — this isn't just a typespec nicety.
  # `:ra_directory`'s DETS-backed server registry (`ra_directory:init/2`) joins
  # this path with a literal filename and hands the result straight to
  # `:dets.open_file/2`; on the OTP/stdlib version pinned here (stdlib 4.2),
  # that call raises `ArgumentError` (`badarg` from `dets.erl:658`) if given a
  # binary path — confirmed by isolating the exact call outside of `:ra`
  # entirely (`:dets.open_file(:x, file: "some/binary/path")` fails the same
  # way with zero `:ra` code involved). `:ra`'s own `default_config/0` never
  # hits this because `ra_env:data_dir/0` always produces a charlist (either
  # from a charlist app-env value or from `file:get_cwd/0`, which itself
  # returns a charlist) — this function preserves that same invariant instead
  # of introducing a binary where `:ra` internals have never had to handle
  # one. `Path.basename/1` (used by `ra_cluster_data_dir_test.exs`) and plain
  # `==` comparison against `:ra_system.fetch(:default)`'s stored config
  # (used by the test below) both work identically whether this returns a
  # charlist or a binary, since whatever's returned here is put into the
  # config verbatim and `:ra_system.fetch/1` returns that config unmodified.
  @spec data_dir() :: charlist()
  def data_dir do
    base = Application.get_env(:ra, :data_dir, File.cwd!()) |> to_string()
    Path.join(base, System.get_env("HOSTNAME", "nonode")) |> String.to_charlist()
  end

  # Recovers a member that already has on-disk log data for this uid on
  # THIS EXACT node() identity — only correct to call when the current,
  # freshly-discovered consensus membership already lists `node()` as a
  # member (see `Riptide.PlacementMembership.bootstrap_once/0`), since
  # `:ra.restart_server/2` looks up on-disk state by the exact `{name, node}`
  # server id, not by uid/data_dir alone. Deliberately NOT used to recover a
  # node whose `node()` identity has drifted since its last run (e.g. a real
  # Kubernetes pod restart under a new IP — `node()` is IP-based and
  # unstable, per `data_dir/0`'s own doc): a drifted node is never listed
  # under ITS NEW identity in the old consensus state, so this call would
  # simply fail to find anything to restart. That case is handled instead by
  # the ordinary ambient join loop (this "new" node joins fresh) plus the
  # leader-only repair loop (evicts the stale old identity) — no special
  # casing needed, it falls out of machinery already built for the
  # dead-member-replacement case generally.
  @spec restart_local_placement_member() :: :ok | {:error, term()}
  def restart_local_placement_member do
    ensure_system_started()
    :ra.restart_server(@system, {@placement_cluster_name, node()})
  end

  # A fast, LOCAL-only membership check: does this node currently have a
  # live placement-cluster member, and if so, what does Raft consensus
  # itself say the full current membership is? `:ra.members/1`'s reply is
  # self-describing and authoritative the instant any single caught-up
  # member answers it — not a guess, a consensus fact (the same principle
  # `remove_member/2`'s own `member_removed?/2` helper below already relies
  # on). Returns `:error` (not raising) when this node has no live local
  # member, mirroring `placement_leader?/0`'s own `catch :exit` treatment.
  @spec local_placement_members() :: {:ok, [node()]} | :error
  def local_placement_members do
    case :ra.members({@placement_cluster_name, node()}) do
      {:ok, members, _leader} -> {:ok, Enum.map(members, fn {_name, n} -> n end)}
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  # The fleet-wide discovery fallback: ask every candidate node, in
  # parallel, whether IT has a live placement-cluster member — the first one
  # that answers wins, since any caught-up member's view of membership is
  # authoritative (see `local_placement_members/0`'s own doc). This needs no
  # hardcoded names at all — `candidate_nodes` is expected to be
  # `[node() | Node.list()]`, the already-elastic fleet `libcluster`
  # discovers, not a fixed ordinal list.
  @spec probe_placement_members([node()]) :: {:ok, [node()]} | :error
  def probe_placement_members(candidate_nodes) do
    candidate_nodes
    |> Enum.uniq()
    |> Task.async_stream(&probe_one_placement_member/1, timeout: 6_000, on_timeout: :kill_task)
    |> Enum.find_value(:error, fn
      {:ok, {:ok, members}} -> {:ok, members}
      _ -> nil
    end)
  end

  defp probe_one_placement_member(n) when n == node(), do: local_placement_members()

  defp probe_one_placement_member(n) do
    :erpc.call(n, __MODULE__, :local_placement_members, [], 5_000)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # Forms a brand-new placement cluster across exactly `member_nodes` — the
  # genesis primitive `Riptide.PlacementMembership` calls once it's computed
  # the same deterministic member list every other simultaneously-booting
  # node would independently compute (see its own moduledoc). Generalizes
  # what used to be `attempt_start_placement_cluster/1`'s hardcoded-3-ordinal
  # version: same self-correcting shape (a redundant call whose members are
  # already running also reports `{:error, :cluster_not_formed}` from
  # `:ra.start_cluster/2` itself, corrected here by rechecking local
  # liveness), just parameterized by a real, already-resolved node list
  # instead of resolving symbolic ordinal names via DNS.
  @spec start_genesis_placement_cluster([node()]) :: :ok | {:error, :cluster_not_formed}
  def start_genesis_placement_cluster(member_nodes) do
    ensure_system_started()
    member_ids = Enum.map(member_nodes, &placement_server_id/1)
    machine = {:module, Riptide.Placement.PlacementMachine, %{}}

    configs =
      Enum.map(member_ids, fn id ->
        %{
          id: id,
          uid: @placement_uid,
          cluster_name: "#{@placement_uid}_cluster",
          log_init_args: %{uid: @placement_uid},
          initial_members: member_ids,
          machine: machine
        }
      end)

    case :ra.start_cluster(@system, configs) do
      {:ok, _started, _not_started} ->
        :ok

      {:error, :cluster_not_formed} ->
        if server_alive?(@placement_cluster_name) do
          :ok
        else
          {:error, :cluster_not_formed}
        end
    end
  end

  # This node joins an already-existing placement cluster — the same
  # add-then-start sequence `replace_member/5` below already proves correct
  # (add to the existing cluster's configuration FIRST, then start the
  # joining server), just without a matching `remove_member` step, since
  # joining doesn't evict anyone. `:ra.add_member/2` is a command sent TO an
  # existing member; the caller doesn't need to already be one itself, so
  # this node can safely call it before it has any local server running.
  @spec join_placement_cluster([node()]) :: :ok | {:error, term()}
  def join_placement_cluster(existing_nodes) do
    ensure_system_started()
    existing_ids = Enum.map(existing_nodes, &placement_server_id/1)
    my_id = placement_server_id(node())
    machine = {:module, Riptide.Placement.PlacementMachine, %{}}
    cluster_name = "#{@placement_uid}_cluster"

    with :ok <- add_member(existing_ids, my_id) do
      start_joining_server(cluster_name, my_id, machine, existing_ids)
    end
  end

  # Removes `node_to_remove` from the placement cluster with no replacement
  # — used both for a confirmed-dead member (the repair side of
  # `Riptide.PlacementMembership`'s reconciliation loop) and for shrinking
  # to a lowered target size. Thin wrapper over the same private
  # `remove_member/2` `replace_member/5` already uses, just without the
  # add-a-replacement half of that pipeline.
  @spec remove_placement_member([node()], node()) :: :ok | {:error, term()}
  def remove_placement_member(survivor_nodes, node_to_remove) do
    ensure_system_started()
    survivor_ids = Enum.map(survivor_nodes, &placement_server_id/1)
    target_id = placement_server_id(node_to_remove)
    remove_member(survivor_ids, target_id)
  end

  # Public (not `defp`) specifically so `member_alive?/1` below can call it
  # over `:erpc` for a server id on a remote node, not just the local one.
  @spec server_alive?(atom()) :: boolean()
  def server_alive?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # Public (not `defp`) so callers beyond this module — e.g.
  # `Riptide.Stream.ReplicaHealer` (Phase 3d-ii) — can check a specific
  # stream replica's real liveness, local or remote, the same way this
  # module already does internally for `start_or_join_replicated/3`'s own
  # `NotStarted` handling.
  @spec member_alive?(:ra.server_id()) :: boolean()
  def member_alive?({name, node}) when node == node() do
    server_alive?(name)
  end

  def member_alive?({name, node}) do
    case :erpc.call(node, __MODULE__, :server_alive?, [name], 5_000) do
      true -> true
      false -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Generalizes what used to be attempt_start_placement_cluster/1's per-member-config +
  # `:ra.start_cluster/2` pattern beyond the hardcoded 3 placement ordinals
  # to an arbitrary node list — used by `Riptide.Stream.Placement` (Phase
  # 3c-ii) to form a real, multi-node cluster for a single stream. Shares
  # `uid` across every member's config (each member's data still lives in a
  # distinct, non-colliding directory because it's nested under that node's
  # own HOSTNAME-scoped data_dir — see `data_dir/0`).
  #
  # Self-corrects the same false-failure case documented on
  # `start_genesis_placement_cluster/1`: a redundant call whose members
  # (including this node's own, if present) are already running also
  # reports `{:error, :cluster_not_formed}` from `:ra.start_cluster/2`
  # itself, since its `Started` list only counts servers *this call* newly
  # started, not servers merely alive. This rechecks local liveness before
  # treating that as a genuine failure — but only if this node is actually
  # one of `member_nodes`; if it isn't, the local liveness check is always
  # false, and the error correctly propagates (this node has no way to know
  # whether the *actual* members formed successfully elsewhere).
  #
  # A non-empty `NotStarted` list on the `{:ok, Started, NotStarted}` branch
  # is deliberately treated as a retriable failure, not partial success —
  # `:ra`'s own docs for this return shape say as much ("servers that could
  # not be started need to be retried periodically"). Blindly returning
  # `{:ok, member_ids}` regardless of `NotStarted` was a real, already-shipped
  # bug (Phase 3d-i HA-proof spike, finding 1): a stream whose replica
  # formation lost a race on one member (e.g. that node's local `:ra` system
  # genuinely wasn't started yet — closed by the `ensure_system_started/0`
  # call above being unconditional at application boot now, but this is real
  # defense in depth against any other reason a member fails to start, e.g.
  # a momentary network blip) got cached as fully healthy by
  # `Riptide.Stream.Placement` even though one of its replicas silently never
  # started — permanently, until an unrelated later request happened to land
  # on that exact starved node for that exact stream and re-triggered
  # formation as a side effect. Returning an error here instead routes
  # through `Riptide.Stream.Placement`'s own existing bounded-retry loop
  # (`start_with_retry/6`), which already exists precisely to absorb this
  # kind of transient formation failure.
  @spec start_or_join_replicated(String.t(), [node()], :ra_machine.machine()) ::
          {:ok, [:ra.server_id()]} | {:error, :cluster_not_formed}
  def start_or_join_replicated(uid, member_nodes, machine) do
    ensure_system_started()
    name = String.to_atom(uid)
    member_ids = Enum.map(member_nodes, &{name, &1})

    configs =
      Enum.map(member_ids, fn id ->
        %{
          id: id,
          uid: uid,
          cluster_name: uid <> "_cluster",
          log_init_args: %{uid: uid},
          initial_members: member_ids,
          machine: machine
        }
      end)

    case :ra.start_cluster(@system, configs) do
      {:ok, _started, []} ->
        {:ok, member_ids}

      {:ok, _started, [_ | _] = not_started} ->
        # `NotStarted` also catches members that are already alive but
        # merely weren't *newly* started by this particular call (e.g. a
        # concurrent redundant formation attempt from another node already
        # won for that member) — same false-failure shape as the
        # `{:error, :cluster_not_formed}` branch below, just per-member
        # instead of whole-cluster. Only genuinely-dead members should
        # trigger a retry.
        if Enum.all?(not_started, &member_alive?/1) do
          {:ok, member_ids}
        else
          {:error, :cluster_not_formed}
        end

      {:error, :cluster_not_formed} ->
        if server_alive?(name) do
          {:ok, member_ids}
        else
          {:error, :cluster_not_formed}
        end
    end
  end

  # Grows a stream's already-running `:ra` cluster by one member (`new_node`)
  # and evicts a dead one (`dead_node`) — the real repair primitive behind
  # Phase 3d-ii's automatic replica healing. `survivor_nodes` must be at
  # least one currently-alive member of the cluster (never `dead_node`
  # itself); passing every survivor (not just one) lets `:ra` itself pick a
  # reachable one to route the membership-change commands through, the same
  # `ra_server_id() | [ra_server_id()]` flexibility `:ra.add_member/2` and
  # `:ra.remove_member/2` already support directly.
  #
  # Order matters and is NOT `start_or_join_replicated/3`'s "form a fresh
  # cluster" order — verified against `:ra`'s own growing-a-cluster
  # documentation (`deps/ra/README.md`, "Dynamically Changing Cluster
  # Membership"): add the member to the existing cluster's configuration
  # FIRST, then start the joining server itself with `initial_members` set
  # to just the survivor(s) — reversed, a freshly-started server with no
  # cluster membership entry yet has nothing to catch up from.
  @spec replace_member(String.t(), [node()], node(), node(), :ra_machine.machine()) ::
          :ok | {:error, term()}
  def replace_member(uid, survivor_nodes, dead_node, new_node, machine) do
    ensure_system_started()
    name = String.to_atom(uid)
    survivor_ids = Enum.map(survivor_nodes, &{name, &1})
    dead_id = {name, dead_node}
    new_id = {name, new_node}
    cluster_name = uid <> "_cluster"

    with :ok <- add_member(survivor_ids, new_id),
         :ok <- start_joining_server(cluster_name, new_id, machine, survivor_ids),
         :ok <- remove_member(survivor_ids, dead_id) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end

  # Self-corrects the same "redundant retry after a partial prior success"
  # shape `add_member/2` and `start_joining_server/4` already handle for
  # their own steps of this same `replace_member/5` pipeline (see their own
  # docs) — but unlike `:ra.add_member/2`, which has a dedicated
  # `{:error, :already_member}` atom to self-correct on, `:ra.remove_member/2`
  # returns the SAME `{:error, :not_member}` for two different situations:
  # `dead_id` was never a member (a genuine caller bug) and `dead_id` was
  # ALREADY removed by an earlier, otherwise-successful `replace_member/5`
  # attempt (e.g. this process/node crashed, or the caller's subsequent
  # `Riptide.Placement.replace_member/3` metadata update failed/raised,
  # before this step's own success was ever observed) — confirmed against
  # `deps/ra/src/ra.erl:618-633` and this module's own
  # `ra_cluster_test.exs:330-331` assertion of that literal return value.
  # Without this self-correction, a redundant retry after that exact partial
  # success permanently fails at this step forever: the real Ra cluster
  # already has the correct membership, but `Riptide.Stream.ReplicaHealer`'s
  # caller never reaches the `:ok` branch that updates placement metadata,
  # so the metadata stays wrongly stuck pointing at the already-evicted
  # `dead_id` — and any node whose replacement was a *different* replica for
  # the same repair (e.g. a second concurrent attempt racing this one) can
  # then never be reconciled either. Disambiguates by checking the surviving
  # cluster's own real membership via `:ra.members/1` rather than trusting
  # the ambiguous error atom alone.
  @spec remove_member([:ra.server_id()], :ra.server_id()) ::
          :ok | {:error, term()} | {:timeout, term()}
  defp remove_member(survivor_ids, dead_id) do
    case retry_cluster_change(fn -> :ra.remove_member(survivor_ids, dead_id) end) do
      {:ok, _reply, _leader} ->
        :ok

      {:error, :not_member} ->
        if member_removed?(survivor_ids, dead_id), do: :ok, else: {:error, :not_member}

      {:error, reason} ->
        {:error, reason}

      {:timeout, _} = timeout ->
        timeout
    end
  end

  # Asks each survivor in turn (any single one being briefly unreachable
  # shouldn't block this check) whether `dead_id` is still in its own
  # locally-known membership list, and trusts the first one that answers —
  # Ra membership changes are themselves consensus commands, so any
  # caught-up member's view of current membership is authoritative, not
  # merely a hint. Defaults to `false` (i.e. "not confirmed removed," so the
  # caller keeps the original ambiguous error and the next sweep retries)
  # if every survivor is unreachable — the safe direction to be wrong in,
  # since it costs a retry rather than a false "removed" reported swallowing
  # a genuine failure.
  @spec member_removed?([:ra.server_id()], :ra.server_id()) :: boolean()
  defp member_removed?(survivor_ids, dead_id) do
    Enum.reduce_while(survivor_ids, false, fn survivor_id, _acc ->
      try do
        case :ra.members(survivor_id) do
          {:ok, members, _leader} -> {:halt, dead_id not in members}
          _ -> {:cont, false}
        end
      rescue
        _ -> {:cont, false}
      catch
        :exit, _ -> {:cont, false}
      end
    end)
  end

  # Self-corrects the exact same "redundant retry after a partial prior
  # success" shape `start_new_cluster/4` and `start_genesis_placement_cluster/1`
  # already handle for their own `:ra` calls (see their own docs): if a
  # previous `replace_member/5` attempt's `add_member` step already landed
  # (e.g. this node crashed before reaching `remove_member`), `:ra.add_member/2`
  # now genuinely returns `{:error, :already_member}` for `new_id` — a real,
  # non-transient error `retry_cluster_change/2` deliberately does NOT retry
  # (see its own doc). Without this, that error would fail the whole repair
  # attempt outright on every retry, leaving the stream permanently stuck
  # (finding 3, Phase 3d-ii final review) instead of proceeding on to
  # (re-)ensure the joining server itself is started.
  @spec add_member([:ra.server_id()], :ra.server_id()) ::
          :ok | {:error, term()} | {:timeout, term()}
  defp add_member(survivor_ids, new_id) do
    case retry_cluster_change(fn -> :ra.add_member(survivor_ids, new_id) end) do
      {:ok, _reply, _leader} -> :ok
      {:error, :already_member} -> :ok
      {:error, reason} -> {:error, reason}
      {:timeout, _} = timeout -> timeout
    end
  end

  # Same self-correction idiom as `start_new_cluster/4`'s own "recheck
  # liveness after an error, in case someone else already won" pattern — but
  # checking `member_alive?/1` (local-or-remote, since `new_id`'s node is
  # often a genuinely different physical node than whichever node is running
  # this repair) rather than pattern-matching a specific error shape like
  # `{:error, {:already_started, _pid}}`. Confirmed necessary, not just
  # defensive: `:ra.start_server/5`'s underlying supervisor child-start
  # failure for an id that's already running can come back wrapped as
  # `{:error, {:shutdown, {:failed_to_start_child, ChildId, {:already_started,
  # pid}}}}` rather than the bare tuple (observed via this module's own
  # collapsed-node test, where `new_node` coincides with an already-running
  # survivor) — matching only the unwrapped shape silently let that case fall
  # through as a genuine failure. Checking real liveness instead is robust to
  # whatever exact wrapping `:ra`/its supervisor happens to produce for "this
  # id is already running," the same reasoning `start_new_cluster/4` already
  # established for its own redundant-start races.
  @spec start_joining_server(String.t(), :ra.server_id(), :ra_machine.machine(), [
          :ra.server_id()
        ]) :: :ok | {:error, term()}
  defp start_joining_server(cluster_name, new_id, machine, survivor_ids) do
    case :ra.start_server(@system, cluster_name, new_id, machine, survivor_ids) do
      :ok ->
        :ok

      {:error, reason} ->
        if member_alive?(new_id) do
          :ok
        else
          {:error, reason}
        end
    end
  end

  # `:ra.add_member/2` and `:ra.remove_member/2` both return as soon as their
  # membership-change command is APPENDED to the leader's log
  # (`after_log_append` reply mode — confirmed directly against
  # `deps/ra/src/ra.erl`'s `add_member/3`/`remove_member/3`), not once it's
  # been committed and applied. And `:ra` only permits ONE cluster
  # membership change in flight at a time: "concurrent changes will be
  # rejected by design" (`deps/ra/README.md`, "Dynamically Changing Cluster
  # Membership"). That combination makes `{:error, :cluster_change_not_permitted}`
  # a genuinely transient condition `replace_member/5` can hit back-to-back
  # in two different spots, both confirmed empirically against a real
  # multi-node `:ra` cluster (see `ra_cluster_replace_member_test.exs`):
  #
  #   1. `add_member` itself, when `survivor_nodes` was elected leader only
  #      moments ago (e.g. right after `start_or_join_replicated/3`, or
  #      right after failing over from a just-killed `dead_node`) — every
  #      new leader must commit a no-op entry for its own current term
  #      before ANY membership change is permitted (see the collapsed-node
  #      test in `ra_cluster_test.exs`).
  #   2. `remove_member`, racing ahead of THIS SAME CALL's own `add_member`
  #      change, which hasn't committed+applied yet.
  #
  # Retrying the SAME `:ra` call (never the whole `with` chain, and never
  # more than this one specific error atom) is safe here specifically
  # because `cluster_change_not_permitted` means the change was REJECTED
  # outright — nothing was appended, so nothing can be double-applied by
  # trying again. Any other error (notably a genuine `{:error, :already_member}`
  # for a `new_node` that's already a distinct, non-transient member — see
  # the collapsed-node test's own assertion) is NOT retried and propagates
  # immediately, unchanged.
  @spec retry_cluster_change((-> term()), pos_integer()) :: term()
  defp retry_cluster_change(fun, attempts_left \\ 50) do
    case fun.() do
      {:error, :cluster_change_not_permitted} when attempts_left > 1 ->
        Process.sleep(100)
        retry_cluster_change(fun, attempts_left - 1)

      other ->
        other
    end
  end
end
