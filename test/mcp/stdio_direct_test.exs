defmodule MCP.StdioDirectTest do
  # Use shared EndpointCase for setup like starting registry
  use MCP.EndpointCase, async: false # Correct module name

  alias MCP.Message.V20241105CallToolResult
  alias SSE.ConnectionRegistryServer

  setup do
    # Ensure registry is started (handled by EndpointCase)
    :ok
  end

  test "Dispatcher handles echo tool call correctly for stdio transport" do
    # 1. Generate session ID and register with stdio transport & initialized
    session_id = UUID.uuid4()
    initial_data = %{transport: :stdio, initialized: true}
    :ok = ConnectionRegistryServer.register(ConnectionRegistryServer, session_id, initial_data)

    # 2. Build the request
    request_id = UUID.uuid4()
    message_to_echo = "Hello Direct Dispatch!"
    request = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => "tools/call",
      "params" => %{
        "name" => "echo",
        "arguments" => %{
          "message" => message_to_echo
        }
      }
    }

    # 3. Call the dispatcher directly with EchoServer implementation
    response_tuple = MCP.Dispatcher.handle_request(MCP.EchoServer, session_id, request)

    # 4. Build the expected *successful* response map
    expected_content = [%{"type" => "text", "text" => message_to_echo}]
    call_tool_result_struct = %V20241105CallToolResult{content: expected_content}
    encoded_result = V20241105CallToolResult.encode(call_tool_result_struct)
                       |> Enum.reject(fn {_k, v} -> is_nil(v) end)
                       |> Enum.into(%{})
    expected_response_map = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => encoded_result
    }

    # 5. Assert the dispatcher returned {:ok, expected_response_map}
    assert response_tuple == {:ok, expected_response_map}

    # Cleanup: Unregister session (optional but good practice)
    ConnectionRegistryServer.unregister(ConnectionRegistryServer, session_id)
  end
end
