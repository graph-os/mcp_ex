defmodule Mix.Tasks.Mcp.Sse do
  @moduledoc """
  Starts the MCP server in SSE-only mode.

  This task starts the MCP endpoint exposing only the SSE connection endpoint.

  ## Usage

      mix mcp.sse [--port PORT]

  ## Options

    * `--port` - The port to run the server on (default: 4000)
  """

  # Override the run method to parse arguments before passing to super
  # @impl Mix.Task # Removing as per warning
  def run(args) do
    # Parse command line arguments
    {opts, remaining_args, _} = OptionParser.parse(args, strict: [port: :integer])

    # Store the port in the process dictionary for use in run_implementation
    port = Keyword.get(opts, :port, 4004)
    Process.put(:mcp_port, port)

    # Call parent implementation which will manage the tmux session
    # super(remaining_args) # Remove super call
    run_implementation(remaining_args) # Call local implementation directly
  end

  # Implementation for when the task runs directly or in the tmux session
  defp run_implementation(_args) do
    # Get the port from the process dictionary
    port = Process.get(:mcp_port, 4004)

    # Ensure all applications are started
    Mix.Task.run("app.start")

    # Start additional dependencies
    {:ok, _} = Application.ensure_all_started(:bandit)

    # Log startup info
    Mix.shell().info("""
    Starting MCP Server in SSE-only mode...
      * SSE endpoint: http://localhost:#{port}/sse
      * SSE-only mode enabled.
      * Press Ctrl+C twice to stop.
    """)

    # Start the endpoint
    {:ok, _pid} = MCP.Endpoint.start_link(sse: true, port: port)

    # Keep the VM running
    Process.sleep(:infinity)
  end
end
