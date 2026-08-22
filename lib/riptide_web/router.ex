defmodule RiptideWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json", "turtle", "ld+json"]
  end

  scope "/" do
    pipe_through :api

    get "/health", RiptideWeb.HealthController, :show
  end
end
