defmodule Riptide.Decade.ModelTest do
  use ExUnit.Case, async: false
  use PropCheck
  import PropCheck.StateM

  alias Riptide.Decade.Model

  @moduletag :benchmark
  @moduletag timeout: 300_000

  # Every tenant the model creates gets an unauthenticated `:public` policy
  # (see `Riptide.Decade.Model.create_tenant/0`), so every request the model
  # issues authenticates as the same synthetic caller (no Authorization
  # header -> `Riptide.PublicReadRateLimit`'s IP-keyed fallback, and
  # `Plug.Test.conn/2` always reports the same fake `remote_ip`). A single
  # `run_commands/2` call can easily issue far more than the real,
  # production-sized default limit (60/min, meant to bound one *real*
  # anonymous client, not a whole property-test run simulating thousands of
  # distinct legitimate callers from one shared fake IP) in well under a
  # minute — without this, the property fails on real, expected 429s that
  # have nothing to do with the LDP read/write semantics under test here.
  # `Riptide.AppEnvTestHelpers.put_env/3` (not a raw `Application.put_env`)
  # so the key is restored to its exact prior state afterward, matching
  # every other rate-limit test in this codebase (e.g.
  # `test/riptide/public_read_rate_limit_test.exs`).
  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :public_read_rate_limit, 1_000_000)
    :ok
  end

  property "a random sequence of tenant/resource operations always matches the model", [:verbose] do
    forall cmds <- commands(Model) do
      {history, state, result} = run_commands(Model, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history)}
        State: #{inspect(state)}
        Result: #{inspect(result)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end
end
