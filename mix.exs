defmodule SnowflexDev.MixProject do
  use Mix.Project

  def project do
    [
      app: :snowflex_dev,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SnowflexDev.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:db_connection, "~> 2.7"},
      {:decimal, "~> 2.0"},
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"}
    ]
  end
end
