defmodule RiptideWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  # Never a real stream — just needs to reach `PlacementMachine.get/2`'s O(1)
  # map lookup so `/health/ready` proves the placement Ra cluster answers,
  # without the cost of `Placement.list_all/1`'s full streams-map payload.
  @health_check_stream_id "__riptide_health_check__"

  # Deliberately checks nothing beyond "is Phoenix itself responsive" — a
  # degraded downstream dependency (e.g. an unreachable placement cluster)
  # must never trigger a pod restart, only a readiness failure (see ready/2).
  def live(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  # Riptide.Placement.lookup/1 raises (via with_ordinal_fallback/2 exhausting
  # all 3 placement ordinals) when the shared placement Ra cluster is
  # unreachable — every LDP/SSE/WebSocket request needs this cluster to
  # resolve stream placement, so its reachability is what "ready" means here.
  def ready(conn, _params) do
    Riptide.Placement.lookup(@health_check_stream_id)
    send_resp(conn, 200, "ok")
  rescue
    _ -> send_resp(conn, 503, "not ready")
  catch
    # Riptide.Placement.lookup/1 can genuinely `exit` (not just `raise`) if
    # the local placement Ra member crashes mid-query — see
    # Riptide.RaCluster.process_command/2's own `catch :exit` doc. A plain
    # `rescue` alone doesn't catch that, which would otherwise surface as an
    # uncaught exit (a connection reset) instead of the clean 503 this probe
    # exists to provide.
    :exit, _ -> send_resp(conn, 503, "not ready")
  end
end
