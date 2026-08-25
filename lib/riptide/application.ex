defmodule Riptide.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Riptide.ClusterSupervisor]]}
      ] ++
        placement_bootstrap_children() ++
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
      [{Task, &Riptide.RaCluster.ensure_placement_cluster_started/0}]
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
