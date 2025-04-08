defmodule MCP.Application do
  @moduledoc """
  The MCP application module.

  This module is responsible for starting the MCP server and its dependencies.
  """

  use Application
  require Logger

  @doc false
  def start(_type, _args) do
    # Determine mode from environment variable
    mode = System.get_env("MCP_MODE", "sse") # Default to "sse"

    # --- Configure Logger based on Mode FIRST ---
    if mode == "stdio" do
      # For stdio mode, immediately remove console logging to prevent contamination
      # Logger *should* be started by default, if not this might error.
      # We will rely on file logging configured in StdioServer later.
      Logger.remove_backend(:console)
      # We could also configure file logging here, but StdioServer does it.
    end
    # --- End Logger Config ---

    Logger.info("Starting MCP application in '#{mode}' mode") # This log might still go to console if mode!=stdio

    children = case mode do
      "stdio" ->
        # Start children needed ONLY for stdio mode
        # Crucially, we need the ConnectionRegistryServer for session tracking
        [
          {SSE.ConnectionRegistryServer, name: SSE.ConnectionRegistryServer},
          # Add other direct dependencies of StdioServer if any

          # Option 1: Start StdioServer as a supervised child (if it's OTP compliant)
          # {MCP.StdioServer, []} # Assuming it can be started as a worker/server

          # Option 2: Start a simple Task supervisor to run the blocking StdioServer.start()
          {Task.Supervisor, name: MCP.StdioTaskSupervisor}
        ]

      _ -> # Default to SSE/HTTP mode
        [
          {SSE.ConnectionRegistryServer, name: SSE.ConnectionRegistryServer},
          {DynamicSupervisor, strategy: :one_for_one, name: MCP.SSE.ConnectionSupervisor},
          {Finch, name: MCP.Finch}
        ]
    end

    opts = [strategy: :one_for_one, name: MCP.Supervisor]
    sup_result = Supervisor.start_link(children, opts)

    # If in stdio mode, start the blocking process *after* the supervisor is up
    if mode == "stdio" and elem(sup_result, 0) == :ok do
       Logger.info("Supervisor started, launching StdioServer task...")
       # Option 2 (cont.): Start the blocking function in a task
       Task.Supervisor.start_child(MCP.StdioTaskSupervisor, fn -> MCP.StdioServer.start() end)
    end

    sup_result
  end
end
