defmodule RiptideWeb.Authz.PolicyController do
  @moduledoc """
  Minimal policy management API — `POST`/`GET /tenants/:tenant_id/policies`,
  scoped to tenant-root policies only (see the Phase 4c design spec §8).
  Gated by the same `:tenant`/`:auth`/`:authz` pipeline as the LDP resource
  routes: `Authorize` maps `POST` to `:write` and `GET` to `:read`, with
  `path_segments` defaulting to `[]` (the tenant root) since these routes
  have no `*path` glob — the same permission the bootstrap owner already
  holds is what's required to manage policies here, since this phase has no
  separate `Control` mode.
  """
  use Phoenix.Controller, formats: [:json]

  alias Riptide.Authz.Policy

  def create(conn, params) do
    tenant_id = conn.assigns.tenant_id
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)

    case policy_from_params(params) do
      {:ok, policy} ->
        case store.add_policy(tenant_id, [], policy) do
          :ok -> send_resp(conn, 201, "")
          {:error, :too_many_policies} -> send_resp(conn, 429, "")
        end

      :error ->
        send_resp(conn, 400, "")
    end
  end

  def index(conn, _params) do
    tenant_id = conn.assigns.tenant_id
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)
    policies = store.list_policies(tenant_id, [])

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Enum.map(policies, &policy_to_map/1)))
  end

  defp policy_from_params(%{"effect" => effect, "modes" => modes, "matcher" => matcher})
       when is_list(modes) do
    with {:ok, effect} <- parse_effect(effect),
         {:ok, modes} <- parse_modes(modes),
         {:ok, matcher} <- parse_matcher(matcher) do
      {:ok, %Policy{effect: effect, modes: modes, matcher: matcher}}
    end
  end

  defp policy_from_params(_params), do: :error

  defp parse_effect("allow"), do: {:ok, :allow}
  defp parse_effect("deny"), do: {:ok, :deny}
  defp parse_effect(_other), do: :error

  defp parse_modes(modes) do
    parsed = Enum.map(modes, &parse_mode/1)

    if Enum.all?(parsed, &(&1 != :error)) do
      {:ok, parsed}
    else
      :error
    end
  end

  defp parse_mode("read"), do: :read
  defp parse_mode("write"), do: :write
  defp parse_mode(_other), do: :error

  defp parse_matcher("public"), do: {:ok, :public}
  defp parse_matcher("authenticated"), do: {:ok, :authenticated}
  defp parse_matcher(%{"agent" => subject}) when is_binary(subject), do: {:ok, {:agent, subject}}
  defp parse_matcher(_other), do: :error

  defp policy_to_map(%Policy{effect: effect, modes: modes, matcher: matcher}) do
    %{
      "effect" => Atom.to_string(effect),
      "modes" => Enum.map(modes, &Atom.to_string/1),
      "matcher" => matcher_to_json(matcher)
    }
  end

  defp matcher_to_json(:public), do: "public"
  defp matcher_to_json(:authenticated), do: "authenticated"
  defp matcher_to_json({:agent, subject}), do: %{"agent" => subject}
end
