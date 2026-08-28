defmodule Riptide.AppEnvTestHelpers do
  @moduledoc """
  Sets an `Application` env var for the duration of a test and restores it
  correctly afterward — specifically, restores *absence* as absence, not as
  an explicit `nil`.

  `Application.get_env(app, key)` (no default) returns `nil` both when a key
  was genuinely never set AND when it was explicitly set to `nil` — the two
  are indistinguishable from that one read. Every config key in this
  codebase that has no `config/*.exs` entry and relies purely on a
  call-site default (`Application.get_env(:riptide, :key, SomeDefault)` —
  e.g. `:auth_verifier`, `:authz_store`, `:tenancy_resolver`,
  `:new_stream_rate_limit`, `:new_stream_rate_scale_ms`) is normally
  *absent*, not `nil`-valued. A test that does
  `original = Application.get_env(app, key)` then
  `on_exit(fn -> Application.put_env(app, key, original) end)` looks like a
  correct restore, but when `original` is `nil` (the common case for these
  keys), `put_env(app, key, nil)` doesn't restore "absent" — it explicitly
  sets the key to `nil`, which is a *different, poisoned* state: every
  later call to `Application.get_env(app, key, SomeDefault)` for the rest
  of that same `mix test` process now returns `nil` instead of
  `SomeDefault`, since the 3-arg default only applies when the key is
  entirely missing, not when it's present-but-nil.

  Confirmed as a real, not just theoretical, bug: this exact pattern in
  `test/riptide/new_stream_rate_limit_test.exs` poisoned
  `:new_stream_rate_scale_ms` to `nil` for the rest of the suite once that
  test ran, causing `Hammer.ETS.FixWindowPerKey.hit/5` to crash with
  `** (ArithmeticError) bad argument in arithmetic expression` (`now + nil`)
  in every rate-limit check afterward — the actual root cause of a CI flake
  that had been misdiagnosed as Ra/placement-cluster resource contention
  (see PROGRESS.md's Sub-project 6 section).
  """

  @doc """
  Sets `Application.get_env(app, key)` to `value` for the calling test,
  registering an `on_exit` that restores the key to its exact prior state
  — `Application.delete_env/2` if it was absent, `Application.put_env/3`
  with the original value otherwise.
  """
  @spec put_env(atom(), atom(), term()) :: :ok
  def put_env(app, key, value) do
    ensure_restored(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Captures `key`'s current state (present-with-value, or absent) and
  registers an `on_exit` that restores exactly that state — without
  setting anything itself. For tests where the value gets set later (by
  the test body, not the setup block) but the cleanup guarantee is still
  needed up front.
  """
  @spec ensure_restored(atom(), atom()) :: :ok
  def ensure_restored(app, key) do
    original = Application.get_env(app, key)
    was_set? = Keyword.has_key?(Application.get_all_env(app), key)

    ExUnit.Callbacks.on_exit(fn ->
      if was_set? do
        Application.put_env(app, key, original)
      else
        Application.delete_env(app, key)
      end
    end)

    :ok
  end
end
