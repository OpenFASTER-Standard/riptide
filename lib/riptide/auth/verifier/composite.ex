defmodule Riptide.Auth.Verifier.Composite do
  @moduledoc """
  Tries each configured `Riptide.Auth.Verifier` in order, returning the
  first success or the last failure if none succeed — this is what lets an
  OIDC-issued token and a Riptide-issued password-auth token both work
  through `RiptideWeb.Plugs.Authenticate` unmodified (design spec
  `docs/superpowers/specs/2026-09-01-phase-6o-username-password-auth-design.md`
  §4.5). The default configured list
  (`Application.get_env(:riptide, :auth_verifiers, [...])`) is
  `[Riptide.Auth.Verifier.OIDC, Riptide.Auth.Verifier.Password]`.

  Each sub-verifier's `verify/1` call is wrapped in its own `rescue`/`catch
  :exit` here, rather than trusting every implementation to already be
  exit-safe: `Riptide.Auth.Verifier.OIDC`'s own `rescue` does not catch a
  `GenServer.call` `:exit` signal, which is exactly what happens if OIDC's
  own `Riptide.Auth.JwksStrategy` was never started (a deployment running
  password-auth-only, with no `:oidc_jwks_url` configured — see
  `config/runtime.exs`). Without this, trying `Verifier.OIDC` first against
  a password-auth token on such a deployment could crash the request
  instead of falling through to the next verifier.
  """
  @behaviour Riptide.Auth.Verifier

  @impl true
  def verify(token) when is_binary(token) do
    verifiers =
      Application.get_env(:riptide, :auth_verifiers, [
        Riptide.Auth.Verifier.OIDC,
        Riptide.Auth.Verifier.Password
      ])

    try_verifiers(verifiers, token, {:error, :no_verifiers_configured})
  end

  defp try_verifiers([], _token, last_error), do: last_error

  defp try_verifiers([verifier | rest], token, _last_error) do
    case safe_verify(verifier, token) do
      {:ok, _claims} = success -> success
      {:error, _reason} = error -> try_verifiers(rest, token, error)
    end
  end

  defp safe_verify(verifier, token) do
    verifier.verify(token)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
