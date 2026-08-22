defmodule RiptideWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json", "turtle", "ld+json"]
  end

  scope "/" do
    pipe_through :api

    get "/health", RiptideWeb.HealthController, :show
    get "/resources/*path", RiptideWeb.LDP.ResourceController, :show
    post "/resources/*path", RiptideWeb.LDP.ResourceController, :create_child
    put "/resources/*path", RiptideWeb.LDP.ResourceController, :replace
    delete "/resources/*path", RiptideWeb.LDP.ResourceController, :delete
    patch "/resources/*path", RiptideWeb.LDP.ResourceController, :patch
  end
end
