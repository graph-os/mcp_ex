defmodule MCP.Dispatcher do
  @moduledoc """
  Handles dispatching of MCP requests and notifications.

  This module contains the core logic for validating messages, checking session
  state, and calling the appropriate implementation module callbacks.
  """
  require Logger
  alias SSE.ConnectionRegistryServer # Use the new GenServer

  # Standard JSON-RPC Error Codes (as module attributes)
  # @parse_error -32700 # Unused
  # @invalid_request -32600 # Unused
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # MCP Specific Error Codes (Example)
  @not_initialized -32000
  @protocol_version_mismatch -32001
  # @tool_not_found -32002 # Unused

  # --- Public Dispatch Functions ---

  @doc """
  Handles an incoming JSON-RPC request message.

  Validates session state and delegates to the appropriate method dispatcher.
  """
  def handle_request(implementation_module, session_id, request) do
    method = request["method"]
    params = request["params"] || %{}
    request_id = request["id"]

    # Use the new GenServer lookup directly
    case ConnectionRegistryServer.lookup(session_id) do
      {:ok, session_data} ->
        # For all methods except initialize AND notifications/initialized, ensure the session is initialized
        # The notifications/initialized arrives *after* initialize succeeds on the client,
        # but the server state might not be updated yet due to async nature.
        requires_init_check = method != "initialize" and method != "notifications/initialized"

        if requires_init_check && !Map.get(session_data, :initialized, false) do
          Logger.warning("Session not initialized check failed for method '#{method}'", session_id: session_id)
          # --- BEGIN ADDED CODE ---
          # Construct and send the error via SSE
          error_code = @not_initialized
          error_message = "Session not initialized"
          error_response = %{
            jsonrpc: "2.0",
            id: request_id, # Use the request ID from the failed request
            error: %{code: error_code, message: error_message, data: nil}
          }
          # Use the new GenServer lookup
          case ConnectionRegistryServer.lookup(session_id) do
            {:ok, %{handler_pid: handler_pid}} when is_pid(handler_pid) ->
              Logger.debug("Sending 'Session not initialized' ERROR response via SSE to handler #{inspect handler_pid}")
              send(handler_pid, {:sse_message, error_response})
              # Return minimal success for HTTP response, indicating SSE handled it
              {:ok, %{}}
            _ ->
              Logger.warning("Could not find handler_pid to send 'Session not initialized' error via SSE for session #{session_id}")
              # Fallback: return error tuple for HTTP response
              {:error, {error_code, error_message, nil}}
          end
          # --- END ADDED CODE ---
        else
          try do
            # Delegate to the specific method dispatcher
            Logger.debug("Dispatching method '#{method}' for session #{session_id}")
            dispatch_method(implementation_module, session_id, method, request_id, params, session_data)
          rescue
            e ->
              stacktrace = __STACKTRACE__
              # Log the specific error and stacktrace
              Logger.error("Error dispatching request: #{inspect(e)}", [
                session_id: session_id,
                method: method,
                request_id: request_id,
                params: inspect(params),
                # error: inspect(e), # Redundant, already in message
                stacktrace: inspect(stacktrace)
              ])
              {:error, {@internal_error, "Internal error processing request", nil}} # Simpler error data
          end
        end

      {:error, :not_found} ->
        Logger.error("Session not found during request handling", [session_id: session_id, method: method])
        {:error, {@internal_error, "Session not found", nil}}
    end
  end

  @doc """
  Handles an incoming JSON-RPC notification message.
  """
  def handle_notification(implementation_module, session_id, notification) do
    method = notification["method"]
    params = notification["params"] || %{}

    Logger.debug("Handling notification",
      session_id: session_id,
      method: method
    )

    # Use the new GenServer lookup directly
    case ConnectionRegistryServer.lookup(session_id) do
      {:ok, session_data} ->
        # Process async
        Task.start(fn ->
          try do
            # Delegate to implementation module's notification handler if defined,
            # otherwise ignore (as per previous default behavior).
            if function_exported?(implementation_module, :handle_notification, 4) do
              apply(implementation_module, :handle_notification, [session_id, method, params, session_data])
            else
              # Default: ignore notification
              :ok
            end
          rescue
            e ->
              Logger.error("Error handling notification", [
                session_id: session_id,
                method: method,
                error: inspect(e)
              ])
          end
        end)
        :ok # Always return :ok for notifications

      {:error, :not_found} ->
        Logger.warning("Session not found for notification", session_id: session_id)
        :ok # Still return :ok even if session not found
    end
  end

  @doc """
  Public entry point mirroring the original MCP.Server.dispatch_request/4.
  Used by SSE.ConnectionHandler.
  """
  def dispatch_request(implementation_module, session_id, request, _session_data) do
    # %{ "method" => _method, "id" => _request_id, "params" => _params } = request # These are unused now
    # This function now primarily acts as a wrapper around handle_request
    # to maintain the previous public API signature if needed elsewhere,
    # but the core logic is in handle_request/3.
    # We might simplify this further later.
    handle_request(implementation_module, session_id, request)
  end


  # --- Private Method Dispatcher ---

  defp dispatch_method(implementation_module, session_id, "initialize", request_id, params, _session_data) do
    if supported_version?(params) do
      # Call implementation with arity 3: handle_initialize(session_id, request_id, params)
      case apply(implementation_module, :handle_initialize, [session_id, request_id, params]) do
        {:ok, result} ->
          # Update registry data after successful implementation call using GenServer
          update_result = ConnectionRegistryServer.update_data(session_id, %{
            protocol_version: Map.get(params, "protocolVersion"),
            capabilities: Map.get(result, :capabilities, %{}), # Get capabilities from result
            initialized: true,
            client_info: Map.get(params, "clientInfo", %{})
            # Existing data like PIDs will be merged by update_data
          })

          if update_result == :ok do
            # Implementation and update succeeded, format the response map
            initialize_result_struct = %MCP.Message.V20241105InitializeResult{
              protocolVersion: result.protocolVersion,
              capabilities: result.capabilities, # Use capabilities from result
              serverInfo: result.serverInfo,
              instructions: Map.get(result, :instructions)
            }
            encoded_result =
              MCP.Message.V20241105InitializeResult.encode(initialize_result_struct)
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Enum.into(%{})

            # --- BEGIN ADDED CODE ---
            # Force synchronous read after update to mitigate race condition - NO LONGER NEEDED with GenServer
            # _ = ConnectionRegistryServer.lookup(session_id)
            # Logger.debug("Performed synchronous read after registry update for session #{session_id}")
            # --- END ADDED CODE ---

            # Send InitializeResult event via the corresponding SSE handler process
            # Use GenServer lookup
            case ConnectionRegistryServer.lookup(session_id) do
              {:ok, %{handler_pid: handler_pid}} when is_pid(handler_pid) ->
                Logger.debug("Sending InitializeResult SSE event to handler #{inspect handler_pid} for session #{session_id}. Handler alive? #{Process.alive?(handler_pid)}")
                send(handler_pid, {:sse_event, "InitializeResult", encoded_result})
              {:ok, data} ->
                 Logger.warning("Could not find valid :handler_pid in registry for session #{session_id} during initialize event sending. Data: #{inspect data}")
              {:error, :not_found} ->
                 Logger.warning("Could not find registry entry for session #{session_id} during initialize event sending.")
            end

            # Prepare HTTP response - Minimal success ack
            response = %{jsonrpc: "2.0", id: request_id, result: %{}} # This is the ack map
            {:ok, response} # Return the ack map for the HTTP response
          else
            # Failed to update registry after successful initialize
            Logger.error("Failed to update registry for session #{session_id} after initialize")
            {:error, {@internal_error, "Internal server error updating session state", nil}}
          end
        {:error, reason} -> {:error, reason} # handle_initialize failed
      end
    else
      supported = Enum.join(MCP.supported_versions(), ", ")
      error_message = if params["protocolVersion"], do: "Unsupported protocol version: #{params["protocolVersion"]}. Supported versions: #{supported}", else: "Missing protocolVersion parameter"
      {:error, {@protocol_version_mismatch, error_message, nil}}
    end
  end

  defp dispatch_method(implementation_module, session_id, "ping", request_id, _params, _session_data) do
    case apply(implementation_module, :handle_ping, [session_id, request_id]) do
      {:ok, result} ->
        ping_result = %MCP.Message.V20241105PingResult{}
        response = %{jsonrpc: "2.0", id: request_id, result: Map.merge(MCP.Message.V20241105PingResult.encode(ping_result), result)}
        {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_method(_implementation_module, session_id, "tools/register", request_id, params, session_data) do
    # Delegate to the implementation module's register_tool function
    # Note: Implementation module is now implicitly MCP.DefaultServer or configured server
    tool = params["tool"]
    case validate_tool(tool) do # Assuming validate_tool remains or is moved here
      {:ok, _} ->
        tool_name = tool["name"]
        current_tools = Map.get(session_data, :tools, %{})
        tools = Map.put(current_tools, tool_name, tool)
        # Use GenServer update
        update_result = ConnectionRegistryServer.update_data(session_id, %{tools: tools})
        if update_result == :ok do
          {:ok, %{jsonrpc: "2.0", id: request_id, result: %{}}}
        else
          Logger.error("Failed to update registry for session #{session_id} during tools/register")
          {:error, {@internal_error, "Internal server error updating session state", nil}}
        end
      {:error, reason} ->
        {:error, {@invalid_params, "Invalid tool definition: #{reason}", nil}}
    end
  end

  defp dispatch_method(implementation_module, session_id, "tools/list", request_id, params, session_data) do
    Logger.debug("Dispatching tools/list request", session_id: session_id, request_id: request_id)

    # Look at any tools registered with the session data
    registered_tools = Map.get(session_data, :tools, %{})
    Logger.debug("Session has #{map_size(registered_tools)} registered tools")

    # Also get tools from the implementation module if available
    # This should provide tools defined with the 'tool' macro
    case apply(implementation_module, :handle_list_tools, [session_id, request_id, params]) do
      {:ok, result} ->
        Logger.debug("Implementation module returned #{length(result.tools)} tools")
        tools_list = result.tools

        list_tools_result_struct = %MCP.Message.V20241105ListToolsResult{tools: tools_list}
        # Encode the result struct and then filter out nil values
        encoded_result =
          MCP.Message.V20241105ListToolsResult.encode(list_tools_result_struct)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{})

        # Construct the full JSON-RPC response map
        response = %{jsonrpc: "2.0", id: request_id, result: encoded_result}

        # Send the response as a standard SSE message event
        # Use GenServer lookup
        case ConnectionRegistryServer.lookup(session_id) do
          {:ok, %{handler_pid: handler_pid}} when is_pid(handler_pid) ->
            Logger.debug("Attempting to send tools/list response via SSE to handler #{inspect handler_pid} for session #{session_id}. Handler alive? #{Process.alive?(handler_pid)}")
            Logger.debug("Response data to send: #{inspect response}")
            # Use :sse_message for standard JSON-RPC responses over the stream
            send(handler_pid, {:sse_message, response})
            Logger.debug("Sent tools/list response message to handler #{inspect handler_pid}")
            # Return minimal success for the HTTP response (client ignores this body)
            {:ok, %{}}
          {:ok, data} ->
             Logger.warning("Could not find valid :handler_pid in registry for session #{session_id} during tools/list response sending. Data: #{inspect data}")
             {:error, {@internal_error, "Internal server error finding session handler", nil}}
          {:error, :not_found} ->
             Logger.warning("Could not find registry entry for session #{session_id} during tools/list response sending.")
             {:error, {@internal_error, "Internal server error finding session", nil}}
        end
      # --- BEGIN MODIFIED ERROR HANDLING ---
      {:error, {code, message, data} = reason} ->
        Logger.error("Error getting tools list: #{inspect(reason)}")
        # Construct JSON-RPC error response
        error_response = %{
          jsonrpc: "2.0",
          id: request_id,
          error: %{code: code, message: message, data: data}
        }
        # Send error response via SSE
        # Use GenServer lookup
        case ConnectionRegistryServer.lookup(session_id) do
          {:ok, %{handler_pid: handler_pid}} when is_pid(handler_pid) ->
            Logger.debug("Sending tools/list ERROR response via SSE to handler #{inspect handler_pid}")
            send(handler_pid, {:sse_message, error_response})
            # Return minimal success for HTTP response, indicating SSE handled it
            {:ok, %{}}
          _ ->
            Logger.warning("Could not find handler_pid to send tools/list error via SSE for session #{session_id}")
            # Fallback: return error tuple for HTTP response (original behavior)
            {:error, reason}
        end
      # --- END MODIFIED ERROR HANDLING ---
    end
  end

  defp dispatch_method(implementation_module, session_id, "tools/call", request_id, params, _session_data) do
    # Directly delegate to the implementation module's handle_tool_call function.
    # It is the implementation's responsibility to handle "tool not found".
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    case apply(implementation_module, :handle_tool_call, [session_id, request_id, tool_name, arguments]) do
      {:ok, result} ->
        # Assuming the result from handle_tool_call is the raw data for the 'content' field
        # Let's structure it according to CallToolResultSchema (needs a 'content' list)
        # For the echo tool, the result is %{echo: "..."}. We need to wrap it.
        # A more robust implementation might have handle_tool_call return the full content list.
        # For now, we adapt the simple echo result.
        content_list =
          case result do
            %{echo: msg} -> [%{"type" => "text", "text" => msg}]
            # Add other cases if handle_tool_call returns different structures for other tools
            _ -> [%{"type" => "text", "text" => Jason.encode!(result)}] # Default fallback: encode result as JSON text
          end

        call_tool_result_struct = %MCP.Message.V20241105CallToolResult{content: content_list}
        encoded_result =
          MCP.Message.V20241105CallToolResult.encode(call_tool_result_struct)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{})
        # Construct the full JSON-RPC response map
        response = %{jsonrpc: "2.0", id: request_id, result: encoded_result}
        # Send the response via SSE
        case ConnectionRegistryServer.lookup(session_id) do
          {:ok, %{handler_pid: handler_pid}} when is_pid(handler_pid) ->
            Logger.debug("Attempting to send tools/call response via SSE to handler #{inspect handler_pid}")
            send(handler_pid, {:sse_message, response})
            Logger.debug("Sent tools/call response message to handler #{inspect handler_pid}")
            {:ok, %{}} # Return minimal success for HTTP
          _ ->
            Logger.warning("Could not find handler_pid to send tools/call response via SSE for session #{session_id}")
            {:error, {@internal_error, "Internal server error finding session handler", nil}}
        end

      # Pass through errors from the implementation (e.g., if it returns {:error, {@tool_not_found, ...}})
      # Also send these errors via SSE
      {:error, {code, message, data} = reason} ->
        Logger.error("Error calling tool #{tool_name}: #{inspect(reason)}")
        error_response = %{
          jsonrpc: "2.0",
          id: request_id,
          error: %{code: code, message: message, data: data}
        }
        case ConnectionRegistryServer.lookup(session_id) do
          {:ok, %{handler_pid: handler_pid}} when is_pid(handler_pid) ->
            Logger.debug("Sending tools/call ERROR response via SSE to handler #{inspect handler_pid}")
            send(handler_pid, {:sse_message, error_response})
            {:ok, %{}} # Return minimal success for HTTP
          _ ->
            Logger.warning("Could not find handler_pid to send tools/call error via SSE for session #{session_id}")
            {:error, reason} # Fallback to HTTP error
        end
    end
  end

  defp dispatch_method(implementation_module, session_id, "resources/list", request_id, params, _session_data) do
     case apply(implementation_module, :handle_list_resources, [session_id, request_id, params]) do
       {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
       {:error, reason} -> {:error, reason}
     end
   end

   defp dispatch_method(implementation_module, session_id, "resources/read", request_id, params, _session_data) do
     case apply(implementation_module, :handle_read_resource, [session_id, request_id, params]) do
       {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
       {:error, reason} -> {:error, reason}
     end
   end

   defp dispatch_method(implementation_module, session_id, "prompts/list", request_id, params, _session_data) do
      case apply(implementation_module, :handle_list_prompts, [session_id, request_id, params]) do
        {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp dispatch_method(implementation_module, session_id, "prompts/get", request_id, params, _session_data) do
      case apply(implementation_module, :handle_get_prompt, [session_id, request_id, params]) do
        {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp dispatch_method(implementation_module, session_id, "complete", request_id, params, _session_data) do
      case apply(implementation_module, :handle_complete, [session_id, request_id, params]) do
        {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
        {:error, reason} -> {:error, reason}
      end
    end

  # Fallback for unknown methods
  defp dispatch_method(_implementation_module, _session_id, method, _request_id, _params, _session_data) do
    {:error, {@method_not_found, "Method not found: #{method}", nil}}
  end

  # --- Helpers ---

  defp supported_version?(%{"protocolVersion" => version}), do: MCP.supports_version?(version)
  defp supported_version?(_), do: false # Handle missing protocolVersion

  # Copied from MCP.Server - consider moving to a shared location if needed elsewhere
  defp validate_tool(tool) do
    cond do
      not is_map(tool) ->
        {:error, "Tool must be a map"}
      not Map.has_key?(tool, "name") ->
        {:error, "Tool must have a name"}
      not Map.has_key?(tool, "description") ->
        {:error, "Tool must have a description"}
      true ->
        {:ok, tool}
    end
  end

end
