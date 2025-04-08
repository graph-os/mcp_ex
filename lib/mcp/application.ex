defmodule MCP.Application do
  @moduledoc """
  The MCP application module.

  This module is responsible for starting the MCP server and its dependencies.
  """

  use Application
  require Logger

  @doc false
  def start(_type, _args) do
    Logger.info("Starting MCP application")

    children = [
      # Start the GenServer registry for SSE connections
      {SSE.ConnectionRegistryServer, name: SSE.ConnectionRegistryServer}, # Use the GenServer module name

      # Start a DynamicSupervisor for SSE Connection Handlers
      # TODO: Consider if this supervisor is still needed or if handlers can be managed differently
      {DynamicSupervisor, strategy: :one_for_one, name: MCP.SSE.ConnectionSupervisor},

      # Start Finch for HTTP requests
      {Finch, name: MCP.Finch}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MCP.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
