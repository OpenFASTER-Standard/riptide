defmodule RiptideWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json", "turtle", "ld+json"]
  end

  pipeline :tenant do
    plug RiptideWeb.Plugs.ResolveTenant
  end

  pipeline :auth do
    plug RiptideWeb.Plugs.Authenticate
  end

  # SSE-only: browsers' native EventSource API can't set custom request
  # headers, so this is the only route allowed to accept a bearer token via
  # `?token=` — see RiptideWeb.Plugs.Authenticate's own moduledoc.
  pipeline :auth_query_param do
    plug RiptideWeb.Plugs.Authenticate, allow_query_param: true
  end

  pipeline :authz do
    plug RiptideWeb.Plugs.Authorize
  end

  scope "/" do
    pipe_through :api

    get "/health/live", RiptideWeb.HealthController, :live
    get "/health/ready", RiptideWeb.HealthController, :ready
  end

  scope "/" do
    pipe_through [:api, :auth_query_param]

    get "/streams/:stream_id/subscribe", RiptideWeb.Realtime.SseController, :subscribe
  end

  scope "/hub" do
    pipe_through [:api, :auth]

    get "/search", RiptideWeb.Hub.DiscoveryController, :search
    get "/entries/:node_id", RiptideWeb.Hub.DiscoveryController, :show
  end

  scope "/tenants/:tenant_id" do
    pipe_through [:api, :tenant, :auth, :authz]

    get "/resources/*path", RiptideWeb.LDP.ResourceController, :show
    post "/resources/*path", RiptideWeb.LDP.ResourceController, :create_child
    put "/resources/*path", RiptideWeb.LDP.ResourceController, :replace
    delete "/resources/*path", RiptideWeb.LDP.ResourceController, :delete
    patch "/resources/*path", RiptideWeb.LDP.ResourceController, :patch

    post "/policies", RiptideWeb.Authz.PolicyController, :create
    get "/policies", RiptideWeb.Authz.PolicyController, :index

    post "/hub/propose", RiptideWeb.Hub.ProposeController, :propose
  end
end
