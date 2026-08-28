import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/riptide start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :riptide, RiptideWeb.Endpoint, server: true
end

config :riptide, RiptideWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# `:ra`'s data_dir must be read here, not in config.exs: config.exs is
# compile-time config baked into a `mix release` at *build* time, so it can
# only ever see the builder container's environment. This has to be runtime
# config so a released image honors whatever `RIPTIDE_RA_DATA_DIR` (e.g.
# `/data`, matching the Dockerfile's `VOLUME ["/data"]`) the *runtime*
# container is actually started with. `:test` is excluded so
# config/test.exs's fixed `priv/ra_data_test` (isolated from dev data, no
# env var involved) keeps taking precedence, matching prior behavior.
#
# Also passed straight into Erlang code (`dets:open_file/2` among others)
# that expects a `file:filename()` charlist, not an Elixir binary — passing
# a binary here compiles fine but blows up at runtime with a
# `dets:open_file` badarg the first time a Ra system tries to start.
if config_env() != :test do
  config :ra,
    data_dir: System.get_env("RIPTIDE_RA_DATA_DIR", "priv/ra_data") |> String.to_charlist()
end

# Opt-in single-node override, mirroring config/dev.exs's and config/test.exs's
# own identical `ordinal_resolver` override (see either's comment for the full
# rationale) — collapses all 3 placement ordinals to whatever node this
# process actually is. A real single-machine deployment outside Kubernetes
# (Fly.io, plain `docker run`/`docker-compose`) has no headless-service DNS
# resolving "riptide-0"/"riptide-1"/"riptide-2" the way
# `default_ordinal_resolver/1`'s real-DNS fallback expects. Without this,
# `/health/ready` — and every LDP/SSE/WebSocket request, all of which route
# through `Riptide.Placement.lookup/1` — permanently 503s on any such
# deployment (confirmed live on Fly.io: `nxdomain` resolving each ordinal).
# A deployment opting into this must ALSO run with `HOSTNAME` set to one of
# the 3 fixed ordinals ("riptide-0"/"riptide-1"/"riptide-2") for
# `Riptide.Application.placement_bootstrap_children/0`'s own separate gate to
# even attempt bootstrapping the (now single-member) placement cluster.
if System.get_env("RIPTIDE_SINGLE_NODE") do
  config :riptide, ordinal_resolver: fn _ordinal -> node() end
end

# Only present when the k8s/statefulset.yaml pod spec's Downward API sets it —
# everywhere else (local dev, docker-compose, tests) libcluster stays configured
# with an empty topology list, making Cluster.Supervisor an inert no-op (see
# Riptide.Application). See Phase 3b design spec §4.
if System.get_env("POD_IP") do
  config :libcluster,
    topologies: [
      riptide: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: System.get_env("RIPTIDE_HEADLESS_SERVICE", "riptide-headless"),
          application_name: "riptide",
          polling_interval: 5_000
        ]
      ]
    ]
end

# OIDC config is optional outside :test — Riptide.Application's
# auth_children/0 only starts Riptide.Auth.JwksStrategy when
# :oidc_jwks_url is actually set, so a deployment that hasn't configured an
# identity provider yet still boots (every request's current_subject is
# simply always nil — no enforcement exists until Phase 4c). :test is
# excluded entirely: config/test.exs deliberately leaves this unset so the
# test suite's own app boot never tries to reach a real JWKS endpoint.
if config_env() != :test do
  oidc_issuer = System.get_env("RIPTIDE_OIDC_ISSUER")
  oidc_audience = System.get_env("RIPTIDE_OIDC_AUDIENCE")
  oidc_jwks_url = System.get_env("RIPTIDE_OIDC_JWKS_URL")

  if oidc_issuer && oidc_audience && oidc_jwks_url do
    config :riptide,
      oidc_issuer: oidc_issuer,
      oidc_audience: oidc_audience,
      oidc_jwks_url: oidc_jwks_url
  end
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :riptide, RiptideWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://ninenines.eu/docs/en/ranch/2.0/guide/listeners/
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :riptide, RiptideWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :riptide, RiptideWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
