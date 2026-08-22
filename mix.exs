defmodule Riptide.MixProject do
  use Mix.Project

  def project do
    [
      app: :riptide,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Riptide.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:rdf, "~> 3.0"},
      {:json_ld, "~> 1.0"}
    ]
  end
end
