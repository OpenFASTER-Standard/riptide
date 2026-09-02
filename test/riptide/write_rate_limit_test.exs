defmodule Riptide.WriteRateLimitTest do
  use ExUnit.Case, async: false

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :write_rate_limit, 2)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :write_rate_scale_ms, :timer.minutes(1))
    :ok
  end

  test "check/1 allows up to the configured limit, then denies" do
    tenant_id = "tenant-#{System.unique_integer([:positive])}"

    assert Riptide.WriteRateLimit.check(tenant_id) == :allow
    assert Riptide.WriteRateLimit.check(tenant_id) == :allow
    assert Riptide.WriteRateLimit.check(tenant_id) == :deny
  end

  test "check/1 tracks distinct tenants independently" do
    tenant_a = "tenant-a-#{System.unique_integer([:positive])}"
    tenant_b = "tenant-b-#{System.unique_integer([:positive])}"

    assert Riptide.WriteRateLimit.check(tenant_a) == :allow
    assert Riptide.WriteRateLimit.check(tenant_a) == :allow
    assert Riptide.WriteRateLimit.check(tenant_a) == :deny

    assert Riptide.WriteRateLimit.check(tenant_b) == :allow
  end
end
