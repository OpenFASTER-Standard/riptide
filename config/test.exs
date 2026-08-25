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

# No real headless-service DNS exists in this environment — every ordinal
# resolves to whichever node is actually asking, which is correct for both
# the single-node async suite (test_helper.exs bootstraps all 3 fixed
# ordinals collapsed onto this one node) and real :peer-based multi-node
# integration tests (every peer that's genuinely a placement-cluster member
# addresses its own real local member this way — see Phase 3c-ii plan Task
# 6). Never applies outside MIX_ENV=test — config/runtime.exs (real
# Kubernetes) is untouched and keeps using real DNS.
config :riptide, ordinal_resolver: fn _ordinal -> node() end
