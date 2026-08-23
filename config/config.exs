# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :riptide,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :riptide, RiptideWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: RiptideWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Riptide.PubSub

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# `:ra`'s data_dir is passed straight into Erlang code (`dets:open_file/2`
# among others) that expects a `file:filename()` charlist, not an Elixir
# binary — passing a binary here compiles fine but blows up at runtime with
# a `dets:open_file` badarg the first time a Ra system tries to start.
config :ra,
  data_dir: System.get_env("RIPTIDE_RA_DATA_DIR", "priv/ra_data") |> String.to_charlist()

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
