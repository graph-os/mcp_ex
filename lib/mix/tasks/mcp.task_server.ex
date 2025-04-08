defmodule Mix.Tasks.Mcp.TaskServer do
  use Mix.Task
  require Logger

  @shortdoc "Starts an MCP SSE server for running Mix tasks."

  @impl Mix.Task
  def run(args) do
    # Parse options
    {opts, _, _} = OptionParser.parse(args, switches: [
      port: :integer,
      path: :string,
      host: :string
    ])

    port = Keyword.get(opts, :port, 4500)
    path = Keyword.get(opts, :path, "/") # Just the base path, router handles the rest
    host = Keyword.get(opts, :host, "localhost")

    # Configure Logger (e.g., to a file or keep console for server)
    Logger.configure(level: :info) # Adjust level as needed
    Logger.info("Starting MCP Task Server...")

    # Ensure applications are started
    Application.ensure_all_started(:mcp)
    Application.ensure_all_started(:bandit) # Ensure Bandit is started
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:uuid)

    # Configuration for MCP.Endpoint
    endpoint_config = [
      server: MCP.TaskServerImpl, # Use our new implementation module
      port: port,
      host: host,
      path_prefix: path, # Let Endpoint/Router handle adding /sse, /rpc etc.
      mode: :sse # Force SSE mode
    ]

    Logger.info("Starting MCP Endpoint with config: #{inspect endpoint_config}")

    # Start the MCP Endpoint which includes the web server (Bandit)
    case MCP.Endpoint.start_link(endpoint_config) do
      {:ok, _pid} ->
        Logger.info("MCP Task Server listening on http://#{host}:#{port}#{path}sse") # Log effective SSE path
        # Keep the task running indefinitely
        Process.sleep(:infinity)
      {:error, reason} ->
        Logger.error("Failed to start MCP Endpoint: #{inspect(reason)}")
        exit({:error, reason})
    end
  end
end
