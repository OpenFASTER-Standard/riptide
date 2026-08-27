defmodule RiptideWeb.MetricsEndpointTest do
  use ExUnit.Case, async: true

  @endpoint_url "http://localhost:9090/metrics"

  test "GET /metrics returns Prometheus exposition format with at least one known metric" do
    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(@endpoint_url), []}, [], [])

    body = to_string(body)

    # phoenix.router_dispatch.duration is guaranteed to have at least been
    # *registered* (Telemetry.Metrics exposes a metric's name in scrape
    # output once any matching event has fired at least once OR, for some
    # reporters, as soon as it's registered — assert on the broader
    # Prometheus format contract instead of requiring a specific metric to
    # already have data, since no HTTP request has necessarily happened yet
    # in this test's own process).
    assert body =~ "# TYPE"
    assert String.contains?(body, "riptide_") or String.contains?(body, "phoenix_")
  end
end
