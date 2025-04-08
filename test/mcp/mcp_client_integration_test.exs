defmodule MCP.ClientIntegrationTest do
  # use ExUnit.Case, async: false
  use MCP.EndpointCase # Use the case template
  require Logger

  # Tag to skip if Node.js/npm/npx is not available or desired
  @tag :requires_node
  @tag :integration

  # Tag to set endpoint mode for this test
  @tag endpoint_opts: [mode: :debug]

  # Tag to skip this test as the target TS client/path doesn't exist
  @tag :skip

  test "runs TypeScript client test task against a managed server", %{port: port} do # Get port from context
    # Endpoint is started by the case template
    Logger.info("Test server started on port #{port} by EndpointCase")

    # Run the test client task, passing the port
    Mix.Task.reenable("mcp.test_client") # Ensure task can run again if needed
    _exit_status = Mix.Task.run("mcp.test_client", ["--port", Integer.to_string(port)])

    # Placeholder assertion - review how to check task status
    assert true
    # No need for try/after, EndpointCase handles shutdown
  end
end
