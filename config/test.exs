import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :riptide, RiptideWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IhD3noZJFg5IDxNMm2ia8NRelsuC9FhbxwJRMzEv4hL5SS5+c/Mw5uCvgz7YSS5w",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# See config.exs for why this must be a charlist, not a binary.
config :ra, data_dir: ~c"priv/ra_data_test"

# Riptide.Stream.ReplicaHealer's own moduledoc: sweep/0 is public specifically
# so tests can invoke it directly rather than waiting on the real interval —
# dedicated ReplicaHealer tests already do this. The 30s background timer
# therefore serves no testing purpose here, and iterates every known stream
# (Placement.list_all/0) including long-lived ones like the Hub Catalog's
# :hub scope — confirmed live as a real, intermittent source of test flakes
# (a sweep-triggered repair racing a test's own concurrent read/write against
# the same stream, surfacing as transient :noproc / Ra consistent-query
# errors). Set far longer than any single `mix test` run so it never fires.
config :riptide, replica_healer_sweep_interval_ms: :timer.hours(24)
