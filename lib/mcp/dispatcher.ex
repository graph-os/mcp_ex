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
          # --- Session Not Initialized Error Handling (Modified for stdio/sse) ---
          error_code = @not_initialized
          error_message = "Session not initialized"
          error_response_map = %{
            "jsonrpc" => "2.0",
            "id" => request_id,
            "error" => %{"code" => error_code, "message" => error_message, "data" => nil}
          }

          transport = Map.get(session_data, :transport, :sse) # Check transport
          case transport do
            :stdio ->
              Logger.debug("Returning 'Session not initialized' ERROR response directly for stdio session #{session_id}")
              # Stdio task expects {:error, {code, msg, data}} which it wraps
              {:error, {error_code, error_message, nil}}
            :sse ->
              # Try sending via SSE handler_pid if available
              case Map.get(session_data, :handler_pid) do
                pid when is_pid(pid) ->
                  Logger.debug("Sending 'Session not initialized' ERROR response via SSE to handler #{inspect pid}")
                  send(pid, {:sse_message, error_response_map})
                  {:ok, %{}} # Return minimal success for HTTP
                _ ->
                  Logger.warning("Could not find handler_pid to send 'Session not initialized' error via SSE for session #{session_id}")
                  # Fallback: return error tuple for HTTP response
                  {:error, {error_code, error_message, nil}}
              end
          end
          # --- End Error Handling ---
        else
          # Session found and (if required) initialized, proceed with dispatch
          try do
            Logger.debug("Dispatching method '#{method}' for session #{session_id}")
            # Pass session_data down to dispatch_method
            dispatch_method(implementation_module, session_id, method, request_id, params, session_data)
          rescue
            e ->
              stacktrace = __STACKTRACE__
              # stacktrace = System.stacktrace() # Deprecated
              exception_details = %{
                "exception" => inspect(e.__struct__),
                "message" => Exception.message(e),
                "stacktrace" => Enum.map(stacktrace, &Exception.format_stacktrace_entry/1) # Use correct format function
              }
              Logger.error("Error dispatching request: #{inspect(exception_details)}")
              {:error, {@internal_error, "Internal error dispatching request", exception_details}}
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

  defp dispatch_method(implementation_module, session_id, "initialize", request_id, params, session_data) do
    if supported_version?(params) do
      case apply(implementation_module, :handle_initialize, [session_id, request_id, params]) do
        {:ok, result} ->
          # Update registry data (common for both stdio and sse)
          update_result = ConnectionRegistryServer.update_data(session_id, %{
            protocol_version: Map.get(params, "protocolVersion"),
            capabilities: Map.get(result, :capabilities, %{}),
            initialized: true,
            client_info: Map.get(params, "clientInfo", %{}),
            server_info: Map.get(result, :serverInfo, %{}) # Store server info too
          })

          if update_result == :ok do
            # Encode the actual InitializeResult payload (common)
            initialize_result_struct = %MCP.Message.V20241105InitializeResult{
              protocolVersion: result.protocolVersion,
              capabilities: result.capabilities,
              serverInfo: result.serverInfo,
              instructions: Map.get(result, :instructions)
            }
            encoded_result_payload =
              MCP.Message.V20241105InitializeResult.encode(initialize_result_struct)
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Enum.into(%{})

            # Check transport type from session data
            transport = Map.get(session_data, :transport, :sse) # Default to :sse

            case transport do
              :stdio ->
                # For stdio, return the full JSON-RPC response map directly
                Logger.debug("Returning full InitializeResult response for stdio session #{session_id}")
                response_map = %{
                  "jsonrpc" => "2.0",
                  "id" => request_id,
                  "result" => encoded_result_payload
                }
                {:ok, response_map}

              :sse ->
                # For SSE, send the InitializeResult event via handler_pid
                case Map.get(session_data, :handler_pid) do
                  pid when is_pid(pid) ->
                    Logger.debug("Sending InitializeResult SSE event to handler #{inspect pid} for session #{session_id}")
                    send(pid, {:sse_event, "InitializeResult", encoded_result_payload})
                  _ ->
                    Logger.warning("Could not find handler_pid for SSE session #{session_id} during initialize event sending.")
                    # Continue anyway, but log warning
                end
                # And return the minimal HTTP ack map for SSE
                ack_map = %{"jsonrpc" => "2.0", "id" => request_id, "result" => %{}}
                {:ok, ack_map}
            end
          else
            Logger.error("Failed to update registry for session #{session_id} after initialize")
            {:error, {@internal_error, "Internal server error updating session state", nil}}
          end
        {:error, reason} -> {:error, reason} # handle_initialize failed
      end
    else
      # Unsupported version error handling (common)
      supported = Enum.join(MCP.supported_versions(), ", ")
      error_message = if params["protocolVersion"], do: "Unsupported protocol version: #{params["protocolVersion"]}. Supported versions: #{supported}", else: "Missing protocolVersion parameter"
      {:error, {@protocol_version_mismatch, error_message, nil}}
    end
  end

  defp dispatch_method(implementation_module, session_id, "ping", request_id, _params, _session_data) do
    case apply(implementation_module, :handle_ping, [session_id, request_id]) do
      {:ok, _result} -> # Ignore result content for ping
        response = %{jsonrpc: "2.0", id: request_id, result: %{}}
        {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_method(_implementation_module, session_id, "tools/register", request_id, params, session_data) do
    tool = params["tool"]
    case validate_tool(tool) do # Assuming validate_tool remains or is moved here
      {:ok, _} ->
        tool_name = tool["name"]
        current_tools = Map.get(session_data, :tools, %{})
        tools = Map.put(current_tools, tool_name, tool)
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
    # Also get tools from the implementation module if available
    case apply(implementation_module, :handle_list_tools, [session_id, request_id, params]) do
      {:ok, result} ->
        # ... (encode result) ...
        encoded_result =
           MCP.Message.V20241105ListToolsResult.encode(%MCP.Message.V20241105ListToolsResult{tools: result.tools})
           |> Enum.reject(fn {_k, v} -> is_nil(v) end)
           |> Enum.into(%{})
        response_map = %{"jsonrpc" => "2.0", "id" => request_id, "result" => encoded_result}

        transport = Map.get(session_data, :transport, :sse)
        case transport do
          :stdio ->
            Logger.debug("Returning tools/list response directly for stdio session #{session_id}")
            {:ok, response_map}
          :sse ->
            case Map.get(session_data, :handler_pid) do
              pid when is_pid(pid) ->
                Logger.debug("Sending tools/list response via SSE to handler #{inspect pid}")
                send(pid, {:sse_message, response_map})
                {:ok, %{}} # Return minimal success for HTTP
              _ ->
                Logger.warning("Could not find handler_pid for SSE session #{session_id} during tools/list response sending.")
                {:error, {@internal_error, "Internal server error finding session handler", nil}}
            end
        end
      {:error, {code, message, data} = reason} ->
        # ... (error handling for tools/list, check transport) ...
        error_response_map = %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "error" => %{"code" => code, "message" => message, "data" => data}
        }
        transport = Map.get(session_data, :transport, :sse)
        case transport do
           :stdio ->
             Logger.debug("Returning tools/list error directly for stdio session #{session_id}")
             {:error, reason} # Let stdio task wrap it
           :sse ->
              case Map.get(session_data, :handler_pid) do
                pid when is_pid(pid) ->
                  Logger.debug("Sending tools/list ERROR response via SSE to handler #{inspect pid}")
                  send(pid, {:sse_message, error_response_map})
                  {:ok, %{}}
                _ ->
                  Logger.warning("Could not find handler_pid to send tools/list error via SSE for session #{session_id}")
                  {:error, reason}
              end
         end
    end
  end

  defp dispatch_method(implementation_module, session_id, "tools/call", request_id, params, session_data) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}
    transport = Map.get(session_data, :transport, :sse)

    case apply(implementation_module, :handle_tool_call, [session_id, request_id, tool_name, arguments]) do
      {:ok, %{content: content_list}} when is_list(content_list) ->
        # ... (encode result) ...
        encoded_result =
           MCP.Message.V20241105CallToolResult.encode(%MCP.Message.V20241105CallToolResult{content: content_list})
           |> Enum.reject(fn {_k, v} -> is_nil(v) end)
           |> Enum.into(%{})
        response_map = %{"jsonrpc" => "2.0", "id" => request_id, "result" => encoded_result}

        case transport do
          :stdio ->
             Logger.debug("Returning tools/call response directly for stdio session #{session_id}")
             {:ok, response_map}
          :sse ->
            # ... (send via handler_pid) ...
            case Map.get(session_data, :handler_pid) do
              pid when is_pid(pid) ->
                 Logger.debug("Sending tools/call response via SSE to handler #{inspect pid}")
                 send(pid, {:sse_message, response_map})
                 {:ok, %{}}
              _ ->
                Logger.warning("Could not find handler_pid for SSE session #{session_id} during tools/call response")
                {:error, {@internal_error, "Internal server error finding session handler", nil}}
            end
        end

      {:error, {code, message, data} = reason} ->
        # ... (error handling for tools/call, check transport) ...
        error_response_map = %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "error" => %{"code" => code, "message" => message, "data" => data}
        }
        case transport do
          :stdio ->
             Logger.debug("Returning tools/call error directly for stdio session #{session_id}")
             {:error, reason} # Let stdio task wrap it
          :sse ->
            # ... (send error via handler_pid) ...
             case Map.get(session_data, :handler_pid) do
                pid when is_pid(pid) ->
                   Logger.debug("Sending tools/call ERROR response via SSE to handler #{inspect pid}")
                   send(pid, {:sse_message, error_response_map})
                   {:ok, %{}}
                _ ->
                  Logger.warning("Could not find handler_pid for SSE session #{session_id} during tools/call error")
                  {:error, reason}
             end
        end
    end
  end

  defp dispatch_method(implementation_module, session_id, "resources/list", request_id, params, session_data) do
     case apply(implementation_module, :handle_list_resources, [session_id, request_id, params]) do
       {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
       {:error, reason} -> {:error, reason}
     end
   end

   defp dispatch_method(implementation_module, session_id, "resources/read", request_id, params, session_data) do
     case apply(implementation_module, :handle_read_resource, [session_id, request_id, params]) do
       {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
       {:error, reason} -> {:error, reason}
     end
   end

   defp dispatch_method(implementation_module, session_id, "prompts/list", request_id, params, session_data) do
      case apply(implementation_module, :handle_list_prompts, [session_id, request_id, params]) do
        {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp dispatch_method(implementation_module, session_id, "prompts/get", request_id, params, session_data) do
      case apply(implementation_module, :handle_get_prompt, [session_id, request_id, params]) do
        {:ok, result} -> {:ok, %{jsonrpc: "2.0", id: request_id, result: result}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp dispatch_method(implementation_module, session_id, "complete", request_id, params, session_data) do
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

  # Validate tool definition (Example - Implement actual validation)
  defp validate_tool(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, nil}
  defp validate_tool(_), do: {:error, "Missing or invalid tool name"}

end
