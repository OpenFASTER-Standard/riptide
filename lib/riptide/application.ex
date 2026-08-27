defmodule Riptide.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Riptide.Telemetry.AccessLog

  @impl true
  def start(_type, _args) do
    # Every fleet node — not just the 3 placement ordinals — can be picked
    # as a replica for a brand-new stream's real multi-member Ra cluster
    # (Phase 3c-ii/3c-iii), and forming that cluster requires this node's
    # own local `:ra` system to already be running by the time a sibling's
    # `:ra.start_cluster/2` call reaches it over RPC. Doing this here,
    # synchronously, before `Cluster.Supervisor`/libcluster even starts
    # connecting to peers, closes that startup race at its root (see Phase
    # 3d-i HA-proof spike, finding 1) rather than relying only on each
    # entry point's own lazy, on-demand call to the same idempotent
    # function.
    Riptide.RaCluster.ensure_system_started()

    # Attached before the supervision tree (and therefore RiptideWeb.Endpoint)
    # starts, so no request can possibly arrive before this handler exists
    # (Phase 5b).
    AccessLog.attach()

    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        Riptide.Telemetry,
        {Plug.Cowboy, scheme: :http, plug: RiptideWeb.MetricsEndpoint, options: [port: 9090]},
        Riptide.Stream.Placement,
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Riptide.ClusterSupervisor]]}
      ] ++
        placement_bootstrap_children() ++
        auth_children() ++
        [
          # Start a worker by calling: Riptide.Worker.start_link(arg)
          # {Riptide.Worker, arg},
          # Start to serve requests, typically the last entry
          RiptideWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Riptide.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Only the 3 fixed placement-cluster ordinals attempt to host a member of
  # it — every other fleet node just consults it via Riptide.Placement, never
  # hosting a replica itself. Runs as a fire-and-forget Task (not a blocking
  # call in start/2 itself) since ensure_placement_cluster_started/0 retries
  # indefinitely until quorum is reachable, which shouldn't hold up the rest
  # of the application (Phoenix Endpoint, etc.) from booting normally.
  defp placement_bootstrap_children do
    if System.get_env("HOSTNAME") in Riptide.RaCluster.placement_ordinals() do
      [
        # `Task`'s own default child_spec restarts as `:temporary` — fine
        # for `ensure_placement_cluster_started/0`'s own {:error, _} branch,
        # which already retries forever internally, but NOT fine for any
        # exception that isn't already anticipated there (e.g. `:ra.start_cluster/2`
        # exiting instead of returning): a `:temporary` Task that dies from
        # one of those is never restarted, silently leaving this ordinal
        # permanently out of the placement cluster for the rest of the
        # pod's lifetime. `ensure_placement_cluster_started/0` is itself
        # documented as safe to call redundantly (self-corrects on
        # `{:error, :cluster_not_formed}` from an already-formed cluster),
        # so a supervisor-driven restart on `:permanent` is a safe, correct
        # recovery path with no special-casing needed here.
        Supervisor.child_spec({Task, &Riptide.RaCluster.ensure_placement_cluster_started/0},
          restart: :permanent
        ),
        Riptide.Stream.ReplicaHealer
      ]
    else
      []
    end
  end

  # Every node that can serve a request needs its own live JWKS signer
  # cache, unlike placement_bootstrap_children/0's 3-ordinal gating — see
  # Riptide.Auth.JwksStrategy's own moduledoc for why no leader coordination
  # is needed here. Conditional on real OIDC config being present at all, so
  # dev/test boot doesn't require a reachable JWKS endpoint just to start —
  # config/test.exs deliberately leaves :oidc_jwks_url unset so individual
  # tests can start their own isolated instance instead (see
  # test/riptide/auth/verifier/oidc_test.exs).
  defp auth_children do
    if Application.get_env(:riptide, :oidc_jwks_url) do
      [Riptide.Auth.JwksStrategy]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RiptideWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
