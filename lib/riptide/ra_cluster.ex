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

  # Fixed, not derived from fleet size — see Phase 3c-i design spec §2/§5. The
  # metadata cluster stays this exact size regardless of how large the overall
  # fleet grows.
  @placement_ordinals ["riptide-0", "riptide-1", "riptide-2"]
  @placement_cluster_name :riptide_placement
  @placement_uid "riptide_placement"

  @spec placement_ordinals() :: [String.t()]
  def placement_ordinals, do: @placement_ordinals

  @spec placement_server_id(String.t(), (String.t() -> node())) :: :ra.server_id()
  def placement_server_id(ordinal, resolve_fun \\ &default_ordinal_resolver/1) do
    {@placement_cluster_name, resolve_fun.(ordinal)}
  end

  # Resolves a StatefulSet ordinal to its *current* Erlang node identity via
  # the headless Service's DNS, mirroring exactly how `Cluster.Strategy.
  # Kubernetes.DNS` (see `config/runtime.exs`) already resolves peers for
  # libcluster. Public (not private) so `Riptide.Placement`'s client
  # functions can reference it as their own default argument value.
  @spec default_ordinal_resolver(String.t()) :: node()
  def default_ordinal_resolver(ordinal) do
    headless_service = System.get_env("RIPTIDE_HEADLESS_SERVICE", "riptide-headless")
    hostname = String.to_charlist("#{ordinal}.#{headless_service}")

    {:ok, {:hostent, _, _, _, _, [ip | _]}} = :inet.gethostbyname(hostname)
    ip_string = ip |> :inet.ntoa() |> to_string()
    String.to_atom("riptide@#{ip_string}")
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

  @spec server_alive?(atom()) :: boolean()
  defp server_alive?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # Retries indefinitely until the placement cluster is formed — intended to
  # be started as a fire-and-forget background task at application boot (see
  # Task 4), not called synchronously from a request path. StatefulSet pods
  # start ordinally by default, so early attempts legitimately fail while
  # sibling ordinals aren't yet reachable; `attempt_fun` returning
  # `{:error, :cluster_not_formed}` is the expected, retriable outcome during
  # that startup window, not a bug.
  @spec ensure_placement_cluster_started(pos_integer(), (-> :ok | {:error, term()})) :: :ok
  def ensure_placement_cluster_started(
        retry_interval_ms \\ 1000,
        attempt_fun \\ &attempt_start_placement_cluster/0
      ) do
    case attempt_fun.() do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(retry_interval_ms)
        ensure_placement_cluster_started(retry_interval_ms, attempt_fun)
    end
  end

  # A single attempt to form (or rejoin) the placement cluster. Safe to call
  # redundantly from multiple ordinals concurrently, and safe to call again on
  # a routine pod restart when the cluster is already running elsewhere — but
  # NOT because `:ra.start_cluster/2` itself tolerates a redundant call
  # transparently. It does not: `:ra.start_cluster/3`'s own `Started` list
  # (confirmed directly against `deps/ra/src/ra.erl:427-465`) tracks only
  # servers *this call* newly started, not servers that are merely alive —
  # so once every member is already running (e.g. because an earlier call,
  # from this same ordinal or another one, already won), every member's
  # per-server `:ra.start_server/2` attempt returns
  # `{:error, {:already_started, pid}}` instead of `ok`, `Started` ends up
  # empty, and `:ra.start_cluster/2` reports the whole call as
  # `{:error, :cluster_not_formed}` — even though the cluster is completely
  # healthy. This function is safe anyway because it self-corrects: on that
  # exact error, it rechecks whether THIS node's own local placement-cluster
  # member is alive (mirroring `start_new_cluster/4`'s own "recheck locally
  # after an error, in case someone else already won" pattern below) and
  # returns `:ok` if so, rather than propagating a false failure. Only a
  # genuine failure to form (the local member really isn't running) still
  # surfaces as `{:error, :cluster_not_formed}`.
  #
  # Uses the same deterministic, non-random uid for every member's config
  # (`@placement_uid`) — each member's data still lives in a distinct,
  # non-colliding directory because it's nested under that node's own
  # HOSTNAME-scoped data_dir (see `RaCluster.data_dir/0`), so a shared uid
  # string across members is correct here, not a collision risk.
  #
  # `resolve_fun` (whether the real `default_ordinal_resolver/1`, doing a live
  # DNS lookup, or a caller-supplied stand-in) can legitimately fail to
  # resolve a sibling ordinal during the normal StatefulSet startup window —
  # `default_ordinal_resolver/1`'s hard match on `:inet.gethostbyname/1`
  # raises `MatchError` in that case rather than returning an error tuple, so
  # we rescue it here and fold it into the same retriable
  # `{:error, :cluster_not_formed}` outcome `:ra.start_cluster/2` itself
  # already returns for "couldn't form the cluster yet" — from
  # `ensure_placement_cluster_started/2`'s point of view, an unresolvable
  # sibling and a cluster that failed to form are the same "try again later"
  # signal, not two different error shapes it needs to distinguish.
  @spec attempt_start_placement_cluster((String.t() -> node())) ::
          :ok | {:error, :cluster_not_formed}
  def attempt_start_placement_cluster(resolve_fun \\ &default_ordinal_resolver/1) do
    ensure_system_started()

    try do
      member_ids = Enum.map(@placement_ordinals, &placement_server_id(&1, resolve_fun))

      configs =
        Enum.map(member_ids, fn id ->
          %{
            id: id,
            uid: @placement_uid,
            cluster_name: "#{@placement_uid}_cluster",
            log_init_args: %{uid: @placement_uid},
            initial_members: member_ids,
            machine: {:module, Riptide.Placement.PlacementMachine, %{}}
          }
        end)

      case :ra.start_cluster(@system, configs) do
        {:ok, _started, _not_started} ->
          :ok

        {:error, :cluster_not_formed} ->
          # See the moduledoc comment above: a redundant call whose members
          # (including this node's own) are already running also reports
          # `:cluster_not_formed`, indistinguishable at this point from a
          # genuine failure to reach quorum unless we check locally.
          if server_alive?(@placement_cluster_name) do
            :ok
          else
            {:error, :cluster_not_formed}
          end
      end
    rescue
      MatchError -> {:error, :cluster_not_formed}
    end
  end
end
