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

# Configure Elixir's Logger. metadata: :all (not an explicit key list) means
# every Logger.metadata/1-set or per-call key that's actually present on a
# given log line gets printed — Credo's own Warning.MissingLoggerMetadataKeys
# check (mix credo --strict) flags any custom metadata key used anywhere in
# the app that isn't declared here, and an explicit list would need updating
# every time a new key is introduced. Values the default text formatter
# can't render (e.g. tuples like :mfa) are already silently excluded by
# Logger.Formatter's own printable-type filter, so :all doesn't clutter dev
# console output with unprintable noise.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: :all

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# joken_jwks (Phase 4b) fetches JWKS documents over HTTPS via Tesla. Tesla's
# own built-in default adapter is already Tesla.Adapter.Httpc (OTP's
# :inets/:httpc — no extra dependency needed), but joken_jwks's own
# HttpFetcher hardcodes a *different* fallback (Tesla.Adapter.Hackney) if
# neither this key nor a per-module override is set. Setting it here
# explicitly keeps :hackney out of the dependency tree entirely.
config :tesla, adapter: Tesla.Adapter.Httpc

# `:ra`'s data_dir is env-var-driven (`RIPTIDE_RA_DATA_DIR`, see
# config/runtime.exs) so it must NOT be set here: config.exs is compile-time
# config, baked into a `mix release` at build time, so reading the env var
# here would bake in whatever (or nothing) was set in the *builder* container
# rather than the value the *runtime* container actually sets — silently
# ignoring the `-e RIPTIDE_RA_DATA_DIR=/data` convention documented on the
# Dockerfile's `VOLUME ["/data"]`. See config/runtime.exs for the real
# config, and its comment for the `dets:open_file/2` charlist requirement.

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
