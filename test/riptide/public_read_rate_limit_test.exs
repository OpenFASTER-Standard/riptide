defmodule Riptide.PublicReadRateLimitTest do
  use ExUnit.Case, async: false

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :public_read_rate_limit, 2)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :public_read_rate_scale_ms, :timer.minutes(1))
    :ok
  end

  test "check/1 allows up to the configured limit, then denies" do
    key = "reader-#{System.unique_integer([:positive])}"

    assert Riptide.PublicReadRateLimit.check(key) == :allow
    assert Riptide.PublicReadRateLimit.check(key) == :allow
    assert Riptide.PublicReadRateLimit.check(key) == :deny
  end

  test "check/1 tracks distinct keys independently" do
    key_a = "reader-a-#{System.unique_integer([:positive])}"
    key_b = "reader-b-#{System.unique_integer([:positive])}"

    assert Riptide.PublicReadRateLimit.check(key_a) == :allow
    assert Riptide.PublicReadRateLimit.check(key_a) == :allow
    assert Riptide.PublicReadRateLimit.check(key_a) == :deny

    assert Riptide.PublicReadRateLimit.check(key_b) == :allow
  end
end
