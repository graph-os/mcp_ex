defmodule MCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp,
      version: "0.1.0",
      build_path: "_build",
      config_path: "config/config.exs",
      deps_path: "deps",
      lockfile: "mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {MCP.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # UUID generation
      {:uuid, "~> 1.1"},
      # HTTP client for MCP client
      {:finch, "~> 0.19"},
      # Web server
      {:plug, "~> 1.14"},
      {:bandit, "~> 1.0"},
      # JSON handling
      {:jason, "~> 1.2"},
      # JSON Schema validation
      {:ex_json_schema, "~> 0.10.0"},
      {:plug_cowboy, "~> 2.5", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      # {:ecto_sql, "~> 3.6", only: :test} # Removed, UUID dependency is enough
      # {:tmux_runner, path: "../tmux_runner"} # Optional, if using TMUX tasks
    ]
  end
end
