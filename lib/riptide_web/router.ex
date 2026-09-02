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

  scope "/auth" do
    pipe_through [:api]

    post "/signup", RiptideWeb.Auth.SignupController, :create
    post "/login", RiptideWeb.Auth.LoginController, :create
  end

  scope "/" do
    pipe_through [:api]

    get "/tenant-names/:name", RiptideWeb.Auth.TenantNamesController, :show
  end

  # No :api pipeline here — SseController always responds with a fixed
  # "text/event-stream" body (see its own moduledoc-adjacent do_subscribe_existing_stream/3),
  # never content-negotiated JSON/Turtle/JSON-LD, so gating it behind :accepts only serves to
  # reject every real browser EventSource request, which always sends `Accept: text/event-stream`
  # — confirmed live via a genuine 406.
  scope "/" do
    pipe_through [:auth_query_param]

    get "/streams/:stream_id/subscribe", RiptideWeb.Realtime.SseController, :subscribe
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

    post "/tasks", RiptideWeb.TaskController, :create
    post "/query", RiptideWeb.TenantQueryController, :create

    post "/propose", RiptideWeb.TenantProposeController, :propose
    post "/pending-reviews/:node_id/approve", RiptideWeb.TenantReviewController, :approve
    post "/pending-reviews/:node_id/decline", RiptideWeb.TenantReviewController, :decline
    get "/discovery/search", RiptideWeb.TenantDiscoveryController, :search
    get "/entries/:node_id", RiptideWeb.TenantDiscoveryController, :show

    post "/install", RiptideWeb.TenantInstallController, :install
    post "/install-reviews/:node_id/approve", RiptideWeb.TenantInstallController, :approve
    post "/install-reviews/:node_id/decline", RiptideWeb.TenantInstallController, :decline
    post "/install-capability", RiptideWeb.TenantInstallController, :install_capability

    post "/crosswalks", RiptideWeb.TenantCrosswalkController, :propose
    post "/crosswalk-reviews/:node_id/approve", RiptideWeb.TenantCrosswalkController, :approve
    post "/crosswalk-reviews/:node_id/decline", RiptideWeb.TenantCrosswalkController, :decline
    post "/capabilities", RiptideWeb.TenantCapabilityController, :propose
    post "/capability-reviews/:node_id/approve", RiptideWeb.TenantCapabilityController, :approve
    post "/capability-reviews/:node_id/decline", RiptideWeb.TenantCapabilityController, :decline
  end
end
