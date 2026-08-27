import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :riptide, RiptideWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      paths: ["/health/live", "/health/ready"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Structured JSON logging for production log aggregation. dev/test keep
# config/config.exs's plain-text formatter and its narrower [:request_id]
# metadata list unchanged — this override applies to :prod only.
#
# metadata: :all (not an explicit key list) — an explicit list would need a
# new entry added by hand every time any future Logger call anywhere in the
# app attaches a new custom key, silently dropping anything not kept in
# sync. This also means Elixir's own automatically-attached metadata (e.g.
# :pid, :mfa) reaches Riptide.Logger.JSONFormatter.format/4 too, which is
# exactly why that module has its own rescue fallback for non-JSON-encodable
# values.
config :logger, :default_formatter,
  format: {Riptide.Logger.JSONFormatter, :format},
  metadata: :all

# Ensures Riptide.Logger.JSONFormatter's "Z" (UTC) timestamp suffix is always
# honest — Logger's own utc_log defaults to false (local time), and was never
# set anywhere before this, meaning the "Z" suffix only happened to be
# correct because this environment's system timezone is UTC, not because
# anything actually enforced it.
config :logger, utc_log: true

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
