defmodule Riptide.Telemetry.AccessLog do
  @moduledoc """
  Structured, single-line request access logging — replaces Phoenix's
  default two-line unstructured request logging, disabled via
  `plug Plug.Telemetry, ..., log: false` in `RiptideWeb.Endpoint`. Attached
  once, from `Riptide.Application.start/2`, to `[:phoenix, :endpoint, :stop]`.

  The log message bakes method/path/status/duration_ms directly into its own
  text (not metadata-only) so dev/test's plain-text formatter — whose
  metadata allowlist deliberately stays `[:request_id]`, unchanged from
  before this phase — still shows a useful line at the console. The same
  values are ALSO attached as metadata, picked up by production's JSON
  formatter (`metadata: :all` in `config/prod.exs`).
  """
  require Logger

  @doc "Attaches this module's handler. Called once from Riptide.Application.start/2."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(
      "riptide-access-log",
      [:phoenix, :endpoint, :stop],
      &__MODULE__.handle_event/4,
      :ok
    )
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.info(
      "#{conn.method} #{conn.request_path} #{conn.status} (#{duration_ms}ms)",
      method: conn.method,
      path: conn.request_path,
      status: conn.status,
      duration_ms: duration_ms
    )

    :ok
  end
end
