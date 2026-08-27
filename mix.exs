defmodule Riptide.MixProject do
  use Mix.Project

  def project do
    [
      app: :riptide,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Riptide.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      riptide: [
        include_executables_for: [:unix],
        steps: [:assemble]
      ]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:rdf, "~> 3.0"},
      {:json_ld, "~> 1.0"},
      {:uniq, "~> 0.6"},
      {:ra, "~> 2.15.0"},
      {:libcluster, "~> 3.3"},
      # Pinned below joken's own "~> 1.11.10" floor: jose 1.11.11+ uses the
      # `dynamic()` Erlang type in its typespecs, which only exists as a
      # built-in type from OTP 27 onward. This project is pinned to OTP 25
      # (see PROGRESS.md's :ra 2.15.0 rationale), so 1.11.11+ fails to
      # compile here with "type dynamic() undefined". 1.11.10 predates that
      # typespec change and satisfies joken's own requirement unchanged.
      {:jose, "== 1.11.10"},
      {:joken, "~> 2.6"},
      {:joken_jwks, "~> 1.7"},
      {:tesla, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # bench/ only (see bench/README.md) — not needed to build, test, or
      # run Riptide itself.
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end
end
