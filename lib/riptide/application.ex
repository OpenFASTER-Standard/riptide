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
        Riptide.NewStreamRateLimit,
        {Plug.Cowboy, scheme: :http, plug: RiptideWeb.MetricsEndpoint, options: [port: 9090]},
        Riptide.Stream.Placement,
        Riptide.SupervisedProcess.SessionTracker,
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Riptide.ClusterSupervisor]]}
      ] ++
        placement_children() ++
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

  # Every fleet node runs both of these now — Riptide.PlacementMembership's
  # own reconciliation loop (Phase 3e) decides internally whether THIS node
  # should be a placement-cluster member (join if under target size) or act
  # as the repair/shrink leader (only if it currently is one and is the
  # cluster's Raft leader), replacing the old static HOSTNAME-matches-one-
  # of-3-fixed-ordinals gate entirely. Riptide.Stream.ReplicaHealer already
  # only acts when `RaCluster.Placement.placement_leader?/0` is true, so running it
  # unconditionally is safe — it's a no-op everywhere except the one real
  # leader, exactly the same safety property it already had.
  #
  # Riptide.PlacementMembership gets an explicit, generous shutdown timeout:
  # its own `terminate/2` (graceful drain) calls `RaCluster.remove_placement_
  # member/2`, whose underlying `:ra.remove_member/2` can retry up to 50
  # times at 100ms apiece on a transient `:cluster_change_not_permitted`
  # (`retry_cluster_change/2`'s own default in `ra_cluster.ex`) — up to 5
  # seconds. The default Supervisor child shutdown timeout (5000ms) doesn't
  # leave enough margin for that plus the call itself.
  defp placement_children do
    [
      Supervisor.child_spec(Riptide.PlacementMembership, shutdown: 10_000),
      Riptide.Stream.ReplicaHealer
    ]
  end

  # Every node that can serve a request needs its own live JWKS signer
  # cache, unconditionally — unlike placement_children/0, which is also
  # unconditional now but still delegates its own internal gating to
  # Riptide.PlacementMembership/RaCluster.Placement.placement_leader?/0 — see
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
