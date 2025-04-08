defmodule Mix.Tasks.Mcp.Debug do
  @moduledoc """
  Starts the MCP server with debug mode enabled.

  This task starts the MCP endpoint with debugging enabled, exposing
  JSON-based endpoints (no HTML/JS interfaces).

  ## Usage

      mix mcp.debug [--port PORT]

  ## Options

    * `--port` - The port to run the server on (default: 4000)
  """

  require Logger

  @shortdoc "Starts the MCP server in debug mode"

  @switches [port: :integer]
  @aliases [p: :port]

  # Override the run method to parse arguments before passing to super
  # @impl Mix.Task # Removing as per warning
  def run(args) do
    # Parse command-line options
    {opts, parsed_args, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    port = Keyword.get(opts, :port, 4000)

    Mix.shell().info("Starting MCP Debug server on port #{port}...")

    # Pass any remaining arguments to the server start function
    run_implementation(parsed_args, port)
  end

  # Implementation for when the task runs directly or in the tmux session.
  # This function is called by the parent TMUX.Task module and handles the actual
  # server startup with the configured port and debug settings.
  @spec run_implementation(any(), any()) :: no_return()
  defp run_implementation(_remaining_args, port) do
    # Ensure all applications are started
    Mix.Task.run("app.start")

    # Configure debug log level
    Application.put_env(:mcp, MCP, log_level: :debug)

    # Start additional dependencies
    {:ok, _} = Application.ensure_all_started(:bandit)

    # Log startup info
    Mix.shell().info("""
    Starting MCP Debug Server...
      * SSE endpoint: http://localhost:#{port}/sse
      * JSON-RPC endpoint: http://localhost:#{port}/rpc
      * Debug endpoints:
        - http://localhost:#{port}/debug/:session_id
        - http://localhost:#{port}/debug/sessions
        - http://localhost:#{port}/debug/api

    Debug mode enabled (JSON API only).
    Press Ctrl+C twice to stop.
    """)

    # Start the endpoint in debug mode
    {:ok, _pid} = MCP.Endpoint.start_link(debug: true, port: port)

    # Keep the VM running
    Process.sleep(:infinity)
  end
end
