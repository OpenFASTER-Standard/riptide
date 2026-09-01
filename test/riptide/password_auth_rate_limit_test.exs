defmodule Riptide.PasswordAuthRateLimitTest do
  use ExUnit.Case, async: false

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_signup_rate_limit, 2)

    Riptide.AppEnvTestHelpers.put_env(
      :riptide,
      :password_auth_signup_rate_scale_ms,
      :timer.minutes(1)
    )

    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_login_rate_limit, 2)

    Riptide.AppEnvTestHelpers.put_env(
      :riptide,
      :password_auth_login_rate_scale_ms,
      :timer.minutes(1)
    )

    :ok
  end

  test "check_signup/1 allows up to the configured limit, then denies" do
    ip = "signup-ip-#{System.unique_integer([:positive])}"

    assert Riptide.PasswordAuthRateLimit.check_signup(ip) == :allow
    assert Riptide.PasswordAuthRateLimit.check_signup(ip) == :allow
    assert Riptide.PasswordAuthRateLimit.check_signup(ip) == :deny
  end

  test "check_signup/1 tracks distinct IPs independently" do
    ip_a = "signup-ip-a-#{System.unique_integer([:positive])}"
    ip_b = "signup-ip-b-#{System.unique_integer([:positive])}"

    assert Riptide.PasswordAuthRateLimit.check_signup(ip_a) == :allow
    assert Riptide.PasswordAuthRateLimit.check_signup(ip_a) == :allow
    assert Riptide.PasswordAuthRateLimit.check_signup(ip_a) == :deny

    assert Riptide.PasswordAuthRateLimit.check_signup(ip_b) == :allow
  end

  test "check_login/1 allows up to the configured limit, then denies" do
    ip = "login-ip-#{System.unique_integer([:positive])}"

    assert Riptide.PasswordAuthRateLimit.check_login(ip) == :allow
    assert Riptide.PasswordAuthRateLimit.check_login(ip) == :allow
    assert Riptide.PasswordAuthRateLimit.check_login(ip) == :deny
  end

  test "check_login/1 tracks distinct IPs independently" do
    ip_a = "login-ip-a-#{System.unique_integer([:positive])}"
    ip_b = "login-ip-b-#{System.unique_integer([:positive])}"

    assert Riptide.PasswordAuthRateLimit.check_login(ip_a) == :allow
    assert Riptide.PasswordAuthRateLimit.check_login(ip_a) == :allow
    assert Riptide.PasswordAuthRateLimit.check_login(ip_a) == :deny

    assert Riptide.PasswordAuthRateLimit.check_login(ip_b) == :allow
  end
end
