defmodule RiptideWeb.MetricsEndpoint do
  @moduledoc """
  A minimal `Plug.Router`-based HTTP server (not a full `Phoenix.Endpoint` —
  no router/controller/socket machinery needed a second time) serving
  `GET /metrics` in Prometheus exposition format, bound to port 9090.

  A separate port from `RiptideWeb.Endpoint` (4000), deliberately —
  Phase 4d's Ingress only routes port 4000 publicly; port 9090 is
  ClusterIP-only, reachable solely from inside the cluster (a Prometheus
  pod's own scrape), never through the public Ingress/TLS path. Binds in
  every environment, not gated to `:prod` — a self-hoster running one local
  instance should be able to `curl` its own metrics too.
  """
  use Plug.Router

  plug :match
  plug :dispatch

  get "/metrics" do
    body = TelemetryMetricsPrometheus.Core.scrape()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
