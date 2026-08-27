defmodule RiptideWeb.MetricsEndpointTest do
  use ExUnit.Case, async: true

  @endpoint_url "http://localhost:9090/metrics"

  test "GET /metrics returns Prometheus exposition format with at least one known metric" do
    # Ensure at least one metric has real data before scraping — Prometheus
    # metrics with zero recorded events are omitted entirely from scrape
    # output (confirmed by reading
    # deps/telemetry_metrics_prometheus_core/lib/core/exporter.ex), so this
    # calls the real production measurement function rather than relying on
    # other tests' incidental HTTP traffic to have already populated one.
    Riptide.Telemetry.measure_placement_leadership()

    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(@endpoint_url), []}, [], [])

    body = to_string(body)

    assert body =~ "# TYPE"
    assert String.contains?(body, "riptide_") or String.contains?(body, "phoenix_")
  end
end
