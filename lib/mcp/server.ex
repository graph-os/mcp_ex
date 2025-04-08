defmodule MCP.Server do
  @moduledoc """
  Default implementation for MCP (Model Context Protocol) servers.

  This module provides a simplified implementation of the MCP server behavior,
  with default handlers for all callbacks that can be easily overridden.
  """

  require Logger

  defmacro __using__(opts) do
    server_name = Keyword.fetch!(opts, :name)
    server_description = Keyword.get(opts, :description)

    quote do
      @behaviour MCP.ServerBehaviour
      require Logger

      # Store server information for later use
      @server_name unquote(server_name)
      @server_description unquote(server_description)
      @server_version Mix.Project.config()[:version] || "0.1.0"

      # --- Default Behaviour Implementations ---

      @impl true
      def start(_session_id), do: :ok

      @impl true
      def handle_message(session_id, message) do
        # Default implementation delegates to Dispatcher
        MCP.Dispatcher.handle_request(__MODULE__, session_id, message)
      end

      @impl true
      def handle_ping(_session_id, _request_id), do: {:ok, %{message: "pong"}}

      @impl true
      def handle_initialize(_session_id, request_id, params) do
        Logger.debug("Default handle_initialize implementation", request_id: request_id)
        protocol_version = Map.get(params, "protocolVersion", MCP.Message.latest_version())
        {:ok,
         %{
           protocolVersion: protocol_version,
           serverInfo: %{
             "name" => @server_name,
             "version" => @server_version,
             "description" => @server_description
           },
           capabilities: %{
             "supportedVersions" => MCP.Message.supported_versions()
           }
         }}
      end

      # Default implementations for tool-related handlers
      @impl true
      def handle_list_tools(_session_id, request_id, _params) do
        Logger.debug("Default handle_list_tools implementation", request_id: request_id)
        {:ok, %{tools: []}}
      end

      @impl true
      def handle_tool_call(_session_id, request_id, tool_name, _arguments) do
        Logger.debug("Default handle_tool_call implementation", request_id: request_id, tool_name: tool_name)
        {:error, {MCP.Server.tool_not_found(), "Tool not found: #{tool_name}", nil}}
      end

      # Default implementations for resource-related handlers
      @impl true
      def handle_list_resources(_session_id, request_id, _params) do
        Logger.debug("Default handle_list_resources implementation", request_id: request_id)
        {:ok, %{resources: []}}
      end

      @impl true
      def handle_read_resource(_session_id, request_id, params) do
        uri = Map.get(params, "uri", "")
        Logger.debug("Default handle_read_resource implementation", request_id: request_id, uri: uri)
        {:error, {MCP.Server.method_not_found(), "Resource not found: #{uri}", nil}}
      end

      # Default implementations for prompt-related handlers
      @impl true
      def handle_list_prompts(_session_id, request_id, _params) do
        Logger.debug("Default handle_list_prompts implementation", request_id: request_id)
        {:ok, %{prompts: []}}
      end

      @impl true
      def handle_get_prompt(_session_id, request_id, params) do
        prompt_id = Map.get(params, "id", "")
        Logger.debug("Default handle_get_prompt implementation", request_id: request_id, prompt_id: prompt_id)
        {:error, {MCP.Server.method_not_found(), "Prompt not found: #{prompt_id}", nil}}
      end

      @impl true
      def handle_complete(_session_id, request_id, _params) do
        Logger.debug("Default handle_complete implementation", request_id: request_id)
        {:error, {MCP.Server.method_not_found(), "Completion not implemented", nil}}
      end

      # Allow overriding all callbacks
      defoverridable start: 1,
                     handle_message: 2,
                     handle_ping: 2,
                     handle_initialize: 3,
                     handle_list_tools: 3,
                     handle_tool_call: 4,
                     handle_list_resources: 3,
                     handle_read_resource: 3,
                     handle_list_prompts: 3,
                     handle_get_prompt: 3,
                     handle_complete: 3
    end
  end

  # --- Public Utilities ---

  @doc """
  Dispatches an incoming JSON-RPC request message to the appropriate handler
  in the provided implementation module.
  """
  def dispatch_request(implementation_module, session_id, request, _session_data \\ nil) do
    # Delegate to the dispatcher module (which might call back into the implementation)
    MCP.Dispatcher.handle_request(implementation_module, session_id, request)
  end

  @doc """
  Sends a notification to a client.
  """
  def send_notification(session_id, method, params \\ nil) do
    Logger.debug("Attempting to send notification", session_id: session_id, method: method)
    notification = %{jsonrpc: "2.0", method: method, params: params}

    # Use GenServer lookup
    case SSE.ConnectionRegistryServer.lookup(session_id) do
      {:ok, %{handler_pid: handler_pid}} ->
        if Process.alive?(handler_pid) do
          # Assuming the handler_pid is still a GenServer that accepts this cast
          # If handler_pid is the Router process, this cast might need adjustment
          GenServer.cast(handler_pid, {:send_message, notification})
          :ok
        else
          Logger.error("Handler PID not alive for send_notification", session_id: session_id, handler_pid: inspect(handler_pid))
          {:error, :handler_not_alive}
        end
      {:error, :not_found} ->
        Logger.error("Could not find handler PID for send_notification", session_id: session_id)
        {:error, :session_not_found}
    end
  end

  # Error code accessors
  def parse_error, do: -32700
  def invalid_request, do: -32600
  def method_not_found, do: -32601
  def invalid_params, do: -32602
  def internal_error, do: -32603
  def not_initialized, do: -32000
  def protocol_version_mismatch, do: -32000
  def tool_not_found, do: -32000

  # Helper to get session data
  def get_session_data(session_id) do
    # Use GenServer lookup
    SSE.ConnectionRegistryServer.lookup(session_id)
  end
end
