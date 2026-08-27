defmodule Riptide.Authz do
  @moduledoc """
  Transport-agnostic authorization decision point — called identically from
  `RiptideWeb.Plugs.Authorize` (LDP HTTP), `RiptideWeb.Realtime.SseController`,
  and `RiptideWeb.Realtime.ReplicationChannel` (Tasks 4, 7, 8), the same way
  `Riptide.Auth.Verifier`'s `verify/1` is called identically from
  `RiptideWeb.Plugs.Authenticate` and `RiptideWeb.Realtime.Socket.connect/3`
  (Phase 4b). See the Phase 4c design spec §5 for the algorithm this
  implements.
  """

  alias Riptide.Authz.Policy

  @spec evaluate(String.t(), [String.t()], map() | nil, Policy.mode()) :: :allow | :deny
  def evaluate(tenant_id, path_segments, current_subject, mode) do
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)

    matching_policies =
      path_segments
      |> prefixes()
      |> Enum.flat_map(&store.list_policies(tenant_id, &1))
      |> Enum.filter(&applies?(&1, current_subject, mode))

    effect =
      cond do
        Enum.any?(matching_policies, &(&1.effect == :deny)) -> :deny
        Enum.any?(matching_policies, &(&1.effect == :allow)) -> :allow
        true -> :deny
      end

    # `effect`/`mode` are both small, fixed sets (2 values each) — safe to
    # tag without violating the cardinality constraint every other metric in
    # this codebase follows (see Riptide.Telemetry's own moduledoc). Without
    # this, a systemic authz failure (e.g. the policy store starts returning
    # empty for an unrelated reason, so `evaluate/4`'s own default-deny
    # kicks in for every request) is invisible on any dashboard — the only
    # signal would be an HTTP 403-rate bump on the LDP routes, and SSE/WS
    # authorization denials have no equivalent status-coded metric at all.
    :telemetry.execute([:riptide, :authz, :decision], %{}, %{effect: effect, mode: mode})

    effect
  end

  # Every prefix of path_segments, including the empty one (the tenant
  # root): for ["docs", "sub"] this is [[], ["docs"], ["docs", "sub"]] — an
  # ancestor container's policies apply to everything under it.
  defp prefixes(path_segments) do
    Enum.map(0..length(path_segments), &Enum.take(path_segments, &1))
  end

  defp applies?(%Policy{matcher: matcher, modes: modes}, current_subject, mode) do
    mode in modes and matches?(matcher, current_subject)
  end

  defp matches?(:public, _current_subject), do: true
  defp matches?(:authenticated, current_subject), do: not is_nil(current_subject)

  # `subject: nil` never matches, even against a `current_subject` that also
  # lacks a `sub` claim — an `{:agent, nil}` policy would otherwise mean "any
  # authenticated request whose token happens to omit `sub`," which defeats
  # the whole point of an agent-scoped policy (one specific principal, not a
  # class of them). `Riptide.Auth.TokenConfig` now requires `sub` on every
  # verified token, so a `nil` matcher subject should never be created going
  # forward — this guard is defense in depth for any policy that predates
  # that requirement or is inserted through a path other than token-based
  # bootstrap.
  defp matches?({:agent, nil}, _current_subject), do: false

  defp matches?({:agent, subject}, current_subject),
    do: not is_nil(current_subject) and current_subject["sub"] == subject
end
