defmodule Riptide.HubRateLimitTest do
  use ExUnit.Case, async: false

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :hub_read_rate_limit, 2)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :hub_read_rate_scale_ms, :timer.minutes(1))
    Riptide.AppEnvTestHelpers.put_env(:riptide, :hub_propose_rate_limit, 2)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :hub_propose_rate_scale_ms, :timer.minutes(1))
    :ok
  end

  test "check_read/1 allows up to the configured limit, then denies" do
    key = "reader-#{System.unique_integer([:positive])}"

    assert Riptide.HubRateLimit.check_read(key) == :allow
    assert Riptide.HubRateLimit.check_read(key) == :allow
    assert Riptide.HubRateLimit.check_read(key) == :deny
  end

  test "check_read/1 tracks distinct keys independently" do
    key_a = "reader-a-#{System.unique_integer([:positive])}"
    key_b = "reader-b-#{System.unique_integer([:positive])}"

    assert Riptide.HubRateLimit.check_read(key_a) == :allow
    assert Riptide.HubRateLimit.check_read(key_a) == :allow
    assert Riptide.HubRateLimit.check_read(key_a) == :deny

    assert Riptide.HubRateLimit.check_read(key_b) == :allow
  end

  test "check_propose/1 allows up to the configured limit, then denies" do
    tenant_id = "tenant-#{System.unique_integer([:positive])}"

    assert Riptide.HubRateLimit.check_propose(tenant_id) == :allow
    assert Riptide.HubRateLimit.check_propose(tenant_id) == :allow
    assert Riptide.HubRateLimit.check_propose(tenant_id) == :deny
  end

  test "check_propose/1 tracks distinct tenants independently" do
    tenant_a = "tenant-a-#{System.unique_integer([:positive])}"
    tenant_b = "tenant-b-#{System.unique_integer([:positive])}"

    assert Riptide.HubRateLimit.check_propose(tenant_a) == :allow
    assert Riptide.HubRateLimit.check_propose(tenant_a) == :allow
    assert Riptide.HubRateLimit.check_propose(tenant_a) == :deny

    assert Riptide.HubRateLimit.check_propose(tenant_b) == :allow
  end
end
