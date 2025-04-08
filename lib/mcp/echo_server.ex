defmodule MCP.EchoServer do
  @moduledoc """
  A simple MCP Server implementation that provides an "echo" tool.
  """
  @behaviour MCP.ServerBehaviour

  require Logger

  @protocol_version "2024-11-05" # Or your desired supported version

  # --- MCPServer Callbacks ---

  # Callbacks defined by MCP.ServerBehaviour

  @impl MCP.ServerBehaviour
  def start(_session_id), do: :ok

  @impl MCP.ServerBehaviour
  def handle_initialize(_session_id, _request_id, params) do
    Logger.info("[EchoServer] Received initialize request", client_params: params)
    # Simple initialize response
    {:ok, %{
      protocolVersion: @protocol_version,
      capabilities: %{
         tools: %{}
      },
      serverInfo: %{
        name: "MCP Echo Server (Elixir)",
        version: "0.1.0"
      }
    }}
  end

  @impl MCP.ServerBehaviour
  def handle_ping(_session_id, _request_id) do
     {:ok, %{}} # Result content doesn't matter for ping
  end

  @impl MCP.ServerBehaviour
  def handle_list_tools(_session_id, _request_id, _params) do
    Logger.info("[EchoServer] Received list_tools request")
    tools = [
      %{
        name: "echo",
        description: "Echoes back the input message.",
        inputSchema: %{
          "type" => "object",
          "properties" => %{
            "message" => %{
              "type" => "string",
              "description" => "The message to echo."
            }
          },
          "required" => ["message"]
        },
         outputSchema: %{
           "type" => "object",
           "properties" => %{
             "echo" => %{
                "type" => "string",
                "description" => "The echoed message."
              }
           },
           "required" => ["echo"]
         }
      }
    ]
    {:ok, %{tools: tools}}
  end

  @impl MCP.ServerBehaviour
  def handle_tool_call(_session_id, _request_id, "echo", arguments) do
    Logger.info("[EchoServer] Received echo tool call", args: arguments)
    case arguments do
      %{"message" => message_to_echo} when is_binary(message_to_echo) ->
         content = [%{"type" => "text", "text" => message_to_echo}]
        {:ok, %{content: content}}
      _ ->
         # Use error codes defined in MCP.Server
         {:error, {MCP.Server.invalid_params(), "Invalid arguments for echo tool. Expected map with 'message' string.", nil}}
    end
  end

  # Fallback for unknown tools
  @impl MCP.ServerBehaviour
  def handle_tool_call(_session_id, _request_id, unknown_tool_name, _arguments) do
     Logger.warning("[EchoServer] Unknown tool called: #{unknown_tool_name}")
     # Use error codes defined in MCP.Server
     {:error, {MCP.Server.method_not_found(), "Tool '#{unknown_tool_name}' not found.", nil}}
  end

  # Implement other optional callbacks if needed, like handle_notification/4
  # def handle_notification(_session_id, method, params, _session_data), do: :ok

  # Add stubs for missing callbacks to satisfy the behaviour
  @impl MCP.ServerBehaviour
  def handle_message(_session_id, _message), do: {:error, :not_implemented}

  @impl MCP.ServerBehaviour
  def handle_list_resources(_session_id, _request_id, _params), do: {:ok, %{resources: []}}

  @impl MCP.ServerBehaviour
  def handle_read_resource(_session_id, _request_id, params) do
    uri = Map.get(params, "uri", "")
    {:error, {MCP.Server.method_not_found(), "Resource not found: #{uri}", nil}}
  end

  @impl MCP.ServerBehaviour
  def handle_list_prompts(_session_id, _request_id, _params), do: {:ok, %{prompts: []}}

  @impl MCP.ServerBehaviour
  def handle_get_prompt(_session_id, _request_id, params) do
    prompt_id = Map.get(params, "id", "")
    {:error, {MCP.Server.method_not_found(), "Prompt not found: #{prompt_id}", nil}}
  end

  @impl MCP.ServerBehaviour
  def handle_complete(_session_id, _request_id, _params) do
    {:error, {MCP.Server.method_not_found(), "Completion not implemented", nil}}
  end
end
