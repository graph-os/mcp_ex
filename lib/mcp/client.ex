defmodule MCP.Client do
  @moduledoc """
  Client for connecting to Model Context Protocol (MCP) servers over SSE.

  This module provides an Elixir client for MCP servers that uses the Agent pattern
  for managing connection state and handling protocol messages.

  ## Examples

      # Start a new client
      {:ok, client} = MCP.Client.start_link(url: "http://localhost:4000/mcp/sse")

      # Initialize the connection
      {:ok, result} = MCP.Client.initialize(client, protocol_version: "2024-11-05")

      # List available tools
      {:ok, tools} = MCP.Client.list_tools(client)

      # Call a tool
      {:ok, result} = MCP.Client.call_tool(client, "example_tool", %{input: "test"})

      # Stop the client when done
      MCP.Client.stop(client)

  """

  require Logger

  @type client :: pid()
  @type request_id :: integer()
  @type event_handler :: (map() | binary(), client() -> :ok)

  @default_headers [
    {"accept", "text/event-stream"},
    {"cache-control", "no-cache"},
    {"connection", "keep-alive"}
  ]

  @default_timeout 30_000

  @doc """
  Starts a new MCP client linked to the current process.

  ## Options

  * `:url` - The URL of the SSE endpoint (required)
  * `:headers` - Additional HTTP headers to include in the request
  * `:message_endpoint` - The endpoint for sending messages (if known)
  * `:session_id` - The session ID to use (if not provided, one will be generated)
  * `:protocol_version` - The protocol version to use (default: MCP.Message.latest_version())
  * `:auto_initialize` - Whether to automatically initialize the connection (default: true)
  * `:connect_timeout` - Connection timeout in milliseconds (default: 30000)

  ## Returns

  * `{:ok, client()}` - The client was started successfully
  * `{:error, reason}` - The client failed to start
  """
  @spec start_link(Keyword.t()) :: {:ok, client()} | {:error, term()}
  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.get(opts, :headers, @default_headers)
    message_endpoint = Keyword.get(opts, :message_endpoint)
    session_id = Keyword.get(opts, :session_id) || generate_session_id()

    protocol_version =
      Keyword.get(opts, :protocol_version, MCP.Message.latest_version())

    auto_initialize = Keyword.get(opts, :auto_initialize, true)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_timeout)

    # Add session ID to URL if not present
    url = if URI.parse(url).query =~ "sessionId=", do: url, else: add_session_id(url, session_id)

    # Initialize state
    initial_state = %{
      url: url,
      headers: headers,
      message_endpoint: message_endpoint,
      session_id: session_id,
      protocol_version: protocol_version,
      initialized: false,
      connection_pid: nil,
      requests: %{},
      request_id_counter: 1,
      event_handlers: %{},
      tools: [],
      resources: [],
      prompts: []
    }

    # Start the Agent process
    {:ok, client} = Agent.start_link(fn -> initial_state end)

    # Connect to the SSE server
    case connect(client, connect_timeout) do
      {:ok, _state} ->
        # Initialize if requested
        maybe_initialize(client, auto_initialize)

      {:error, reason} = error ->
        Logger.error("Failed to start MCP client: #{inspect(reason)}")
        Agent.stop(client)
        error
    end
  end

  # Helper to handle initialization based on auto_initialize flag
  defp maybe_initialize(client, true) do
    case initialize_internal(client) do
      {:ok, _} ->
        {:ok, client}

      error ->
        Logger.error("Failed to initialize MCP client: #{inspect(error)}")
        Agent.stop(client)
        error
    end
  end

  defp maybe_initialize(client, false), do: {:ok, client}

  @doc """
  Stops the MCP client.

  ## Parameters

  * `client` - The client to stop

  ## Returns

  * `:ok` - The client was stopped successfully
  """
  @spec stop(client()) :: :ok
  def stop(client) do
    # Stop any ongoing connection process
    Agent.get(client, fn state ->
      if state.connection_pid && Process.alive?(state.connection_pid) do
        Process.exit(state.connection_pid, :normal)
      end
    end)

    # Stop the Agent process
    Agent.stop(client)
  end

  @doc """
  Initializes the MCP connection.

  ## Parameters

  * `client` - The client to initialize
  * `opts` - Options for initialization
    * `:protocol_version` - The protocol version to use (default: from client state)
    * `:capabilities` - Client capabilities to advertise (default: %{})
    * `:timeout` - Request timeout in milliseconds (default: 30000)

  ## Returns

  * `{:ok, map()}` - The connection was initialized successfully with result data
  * `{:error, term()}` - The connection failed to initialize
  """
  @spec initialize(client(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def initialize(client, opts \\ []) do
    initialize_internal(client, opts)
  end

  @doc """
  Lists available tools on the server.

  ## Parameters

  * `client` - The client to use
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)
    * `:cursor` - Pagination cursor for fetching more results
    * `:limit` - Maximum number of tools to return

  ## Returns

  * `{:ok, list(map())}` - The tools were listed successfully
  * `{:error, term()}` - The request failed
  """
  @spec list_tools(client(), Keyword.t()) :: {:ok, list(map())} | {:error, term()}
  def list_tools(client, opts \\ []) do
    params =
      %{}
      |> add_param_if_present(:cursor, Keyword.get(opts, :cursor))
      |> add_param_if_present(:limit, Keyword.get(opts, :limit))

    case send_request(client, "tools/list", params, opts) do
      {:ok, response} ->
        tools = response["tools"] || []
        # Update cached tools
        Agent.update(client, fn state -> %{state | tools: tools} end)
        {:ok, tools}

      error ->
        error
    end
  end

  @doc """
  Calls a tool on the server.

  ## Parameters

  * `client` - The client to use
  * `tool_name` - The name of the tool to call
  * `arguments` - The arguments to pass to the tool
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)

  ## Returns

  * `{:ok, map()}` - The tool was called successfully with result data
  * `{:error, term()}` - The request failed
  """
  @spec call_tool(client(), String.t(), map(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def call_tool(client, tool_name, arguments, opts \\ []) do
    params = %{
      name: tool_name,
      arguments: arguments
    }

    case send_request(client, "tools/call", params, opts) do
      {:ok, response} -> {:ok, response}
      error -> error
    end
  end

  @doc """
  Registers a tool with the server.

  ## Parameters

  * `client` - The client to use
  * `tool` - The tool definition to register
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)

  ## Returns

  * `{:ok, map()}` - The tool was registered successfully
  * `{:error, term()}` - The request failed
  """
  @spec register_tool(client(), map(), Keyword.t()) :: {:ok, any()} | {:error, term()}
  def register_tool(client, tool, opts \\ []) do
    # Basic validation of tool structure
    # TODO: Replace with proper schema validation once tool schemas are defined
    case validate_tool(tool) do
      {:ok, _} ->
        _tool_schema = %{
          "type" => "object",
          "required" => ["name", "description"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "inputSchema" => %{"type" => "object"},
            "outputSchema" => %{"type" => "object"}
          }
        }

        # Send the register tool request
        send_request(
          client,
          "tools/register",
          %{tool: tool},
          opts
        )

      {:error, reason} = error ->
        Logger.error("Invalid tool definition: #{inspect(reason)}")
        error
    end
  end

  # Simple tool validation function until we have proper schemas
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

  @doc """
  Lists available resources on the server.

  ## Parameters

  * `client` - The client to use
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)
    * `:cursor` - Pagination cursor for fetching more results
    * `:limit` - Maximum number of resources to return

  ## Returns

  * `{:ok, list(map())}` - The resources were listed successfully
  * `{:error, term()}` - The request failed
  """
  @spec list_resources(client(), Keyword.t()) :: {:ok, list(map())} | {:error, term()}
  def list_resources(client, opts \\ []) do
    params =
      %{}
      |> add_param_if_present(:cursor, Keyword.get(opts, :cursor))
      |> add_param_if_present(:limit, Keyword.get(opts, :limit))

    case send_request(client, "resources/list", params, opts) do
      {:ok, response} ->
        resources = response["resources"] || []
        # Update cached resources
        Agent.update(client, fn state -> %{state | resources: resources} end)
        {:ok, resources}

      error ->
        error
    end
  end

  @doc """
  Reads a resource from the server.

  ## Parameters

  * `client` - The client to use
  * `resource_id` - The ID of the resource to read
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)

  ## Returns

  * `{:ok, String.t()}` - The resource content was read successfully
  * `{:error, term()}` - The request failed
  """
  @spec read_resource(client(), String.t(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def read_resource(client, resource_id, opts \\ []) do
    params = %{
      id: resource_id
    }

    case send_request(client, "resources/read", params, opts) do
      {:ok, response} -> {:ok, response["content"]}
      error -> error
    end
  end

  @doc """
  Lists available prompts on the server.

  ## Parameters

  * `client` - The client to use
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)
    * `:cursor` - Pagination cursor for fetching more results
    * `:limit` - Maximum number of prompts to return

  ## Returns

  * `{:ok, list(map())}` - The prompts were listed successfully
  * `{:error, term()}` - The request failed
  """
  @spec list_prompts(client(), Keyword.t()) :: {:ok, list(map())} | {:error, term()}
  def list_prompts(client, opts \\ []) do
    params =
      %{}
      |> add_param_if_present(:cursor, Keyword.get(opts, :cursor))
      |> add_param_if_present(:limit, Keyword.get(opts, :limit))

    case send_request(client, "prompts/list", params, opts) do
      {:ok, response} ->
        prompts = response["prompts"] || []
        # Update cached prompts
        Agent.update(client, fn state -> %{state | prompts: prompts} end)
        {:ok, prompts}

      error ->
        error
    end
  end

  @doc """
  Gets a prompt from the server.

  ## Parameters

  * `client` - The client to use
  * `prompt_id` - The ID of the prompt to get
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)

  ## Returns

  * `{:ok, map()}` - The prompt was retrieved successfully
  * `{:error, term()}` - The request failed
  """
  @spec get_prompt(client(), String.t(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_prompt(client, prompt_id, opts \\ []) do
    params = %{
      id: prompt_id
    }

    case send_request(client, "prompts/get", params, opts) do
      {:ok, response} -> {:ok, response["prompt"]}
      error -> error
    end
  end

  @doc """
  Sends a completion request to the server.

  ## Parameters

  * `client` - The client to use
  * `params` - The completion parameters
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)

  ## Returns

  * `{:ok, map()}` - The completion request was successful
  * `{:error, term()}` - The request failed
  """
  @spec complete(client(), map(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def complete(client, params, opts \\ []) do
    case send_request(client, "complete", params, opts) do
      {:ok, response} -> {:ok, response}
      error -> error
    end
  end

  @doc """
  Sends a ping request to the server.

  ## Parameters

  * `client` - The client to use
  * `opts` - Options for the request
    * `:timeout` - Request timeout in milliseconds (default: 30000)

  ## Returns

  * `{:ok, map()}` - The ping was successful
  * `{:error, term()}` - The request failed
  """
  @spec ping(client(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def ping(client, opts \\ []) do
    case send_request(client, "ping", %{}, opts) do
      {:ok, response} -> {:ok, response}
      error -> error
    end
  end

  @doc """
  Registers an event handler for SSE events.

  ## Parameters

  * `client` - The client to use
  * `event_type` - The event type to handle
  * `handler` - The handler function: `(event_data, client) -> :ok`

  ## Returns

  * `:ok` - The handler was registered successfully
  """
  @spec register_event_handler(client(), String.t(), event_handler()) :: :ok
  def register_event_handler(client, event_type, handler) when is_function(handler, 2) do
    Agent.update(client, fn state ->
      handlers = Map.get(state.event_handlers, event_type, [])
      %{state | event_handlers: Map.put(state.event_handlers, event_type, [handler | handlers])}
    end)

    :ok
  end

  @doc """
  Unregisters an event handler for SSE events.

  ## Parameters

  * `client` - The client to use
  * `event_type` - The event type to unregister handlers for
  * `handler` - The handler function to unregister (optional)

  ## Returns

  * `:ok` - The handler was unregistered successfully
  """
  @spec unregister_event_handler(client(), String.t(), event_handler() | nil) :: :ok
  def unregister_event_handler(client, event_type, handler \\ nil) do
    Agent.update(client, fn state ->
      if handler do
        handlers = Map.get(state.event_handlers, event_type, [])

        %{
          state
          | event_handlers:
              Map.put(state.event_handlers, event_type, Enum.reject(handlers, &(&1 == handler)))
        }
      else
        %{state | event_handlers: Map.delete(state.event_handlers, event_type)}
      end
    end)

    :ok
  end

  @doc """
  Returns information about the client's current state.

  ## Parameters

  * `client` - The client to get information for

  ## Returns

  * `map()` - Information about the client state
  """
  @spec info(client()) :: map()
  def info(client) do
    Agent.get(client, fn state ->
      %{
        session_id: state.session_id,
        url: state.url,
        message_endpoint: state.message_endpoint,
        protocol_version: state.protocol_version,
        initialized: state.initialized,
        connected: state.connection_pid != nil && Process.alive?(state.connection_pid),
        tools_count: length(state.tools),
        resources_count: length(state.resources),
        prompts_count: length(state.prompts)
      }
    end)
  end

  # Private functions

  @spec initialize_internal(client(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  defp initialize_internal(client, opts \\ []) do
    protocol_version =
      Keyword.get(opts, :protocol_version) ||
        Agent.get(client, fn state -> state.protocol_version end)

    capabilities = Keyword.get(opts, :capabilities, %{})

    params = %{
      protocolVersion: protocol_version,
      capabilities: capabilities
    }

    case send_request(client, "initialize", params, opts) do
      {:ok, response} ->
        # Update the client state with the initialized flag and server info
        Agent.update(client, fn state ->
          %{
            state
            | initialized: true,
              protocol_version: response["protocolVersion"] || protocol_version
          }
        end)

        {:ok, response}

      error ->
        error
    end
  end

  @spec connect(client(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  defp connect(client, timeout) do
    url = Agent.get(client, fn state -> state.url end)
    headers = Agent.get(client, fn state -> state.headers end)
    session_id = Agent.get(client, fn state -> state.session_id end)

    Logger.info("Connecting to MCP server at #{url} with session ID #{session_id}")

    # Start a process to handle the SSE connection
    parent = self()

    connection_pid =
      spawn_link(fn ->
        handle_sse_connection(parent, client, url, headers, timeout)
      end)

    # Update the client state with the connection PID
    Agent.update(client, fn state ->
      %{state | connection_pid: connection_pid}
    end)

    # Wait for the message endpoint to be set
    wait_for_message_endpoint(client, timeout)
  end

  @spec handle_sse_connection(pid(), client(), String.t(), list(), non_neg_integer()) ::
          no_return()
  defp handle_sse_connection(_parent, client, url, headers, timeout) do
    # Build the request using Finch.build
    req = Finch.build(:get, url, headers)

    # Stream the response to handle SSE events
    stream_opts = [receive_timeout: timeout]

    # Create a handler function that closes over the client
    handler = fn chunk, acc -> handle_stream_message(chunk, acc, client) end

    case Finch.stream(req, MCP.Finch, %{}, handler, stream_opts) do
      {:ok, _} ->
        # Connection closed gracefully
        Logger.info("SSE connection closed gracefully")

      {:error, error} ->
        # Connection error
        Logger.error("SSE connection error: #{inspect(error)}")

        # Try to reconnect after a delay
        Process.sleep(5000)
        reconnect(client)
    end
  end

  @spec handle_stream_message(any(), any(), client()) :: {:cont, any()} | {:halt, :error}
  defp handle_stream_message({:status, status}, _acc, _client) do
    Logger.debug("Received status: #{status}")

    if status != 200 do
      Logger.error("Unexpected status code: #{status}")
      {:halt, :error}
    else
      {:cont, :ok}
    end
  end

  defp handle_stream_message({:headers, headers}, acc, _client) do
    Logger.debug("Received headers: #{inspect(headers)}")

    # Check if we have the correct content type
    content_type = List.keyfind(headers, "content-type", 0)

    if content_type && elem(content_type, 1) =~ "text/event-stream" do
      {:cont, acc}
    else
      Logger.error("Unexpected content type: #{inspect(content_type)}")
      {:halt, :error}
    end
  end

  defp handle_stream_message({:data, data}, acc, client) when is_binary(data) do
    # Parse and handle the SSE data
    handle_chunk(client, data)
    {:cont, acc}
  end

  defp handle_stream_message({:data, data}, acc, _client) do
    Logger.debug("Received unknown data format: #{inspect(data)}")
    {:cont, acc}
  end

  defp handle_stream_message(:done, acc, _client) do
    Logger.debug("Stream completed")
    {:cont, acc}
  end

  @spec reconnect(client()) :: :ok
  defp reconnect(client) do
    Logger.info("Attempting to reconnect to SSE endpoint")

    # Get the connection timeout
    timeout = @default_timeout

    # Connect again
    case connect(client, timeout) do
      {:ok, _} ->
        # Re-initialize if needed
        if Agent.get(client, & &1.initialized) do
          initialize_internal(client)
        end

        :ok

      {:error, _reason} ->
        Logger.error("Failed to reconnect")
        # Try again after a delay
        Process.sleep(10000)
        reconnect(client)
    end
  end

  @spec handle_chunk(client(), binary()) :: :ok
  defp handle_chunk(client, chunk) do
    # Parse the SSE events from the chunk
    chunk
    |> String.split("\n\n")
    |> Enum.filter(&(&1 != ""))
    |> Enum.each(fn event_text ->
      case parse_sse_event(event_text) do
        {:ok, event_type, data} ->
          handle_sse_event(client, event_type, data)

        {:error, reason} ->
          Logger.warning("Failed to parse SSE event: #{inspect(reason)}")
      end
    end)
  end

  @spec parse_sse_event(binary()) :: {:ok, String.t(), String.t()} | {:error, :no_data}
  defp parse_sse_event(event_text) do
    # Parse the event type and data from the event text
    event_lines = String.split(event_text, "\n")

    {event_type, data} =
      Enum.reduce(event_lines, {"message", nil}, fn line, {current_event, current_data} ->
        cond do
          String.starts_with?(line, "event:") ->
            {String.trim(String.replace(line, "event:", "")), current_data}

          String.starts_with?(line, "data:") ->
            {current_event, String.trim(String.replace(line, "data:", ""))}

          true ->
            {current_event, current_data}
        end
      end)

    if data do
      {:ok, event_type, data}
    else
      {:error, :no_data}
    end
  end

  @spec handle_sse_event(client(), String.t(), String.t()) :: :ok
  defp handle_sse_event(client, "message", data) do
    # Parse the JSON message
    case Jason.decode(data) do
      {:ok, message} ->
        handle_message(client, message)

      {:error, reason} ->
        Logger.warning("Failed to parse message: #{inspect(reason)}")
    end
  end

  defp handle_sse_event(client, "endpoint", data) do
    # Update the message endpoint
    Agent.update(client, fn state ->
      %{state | message_endpoint: data}
    end)

    # Notify any registered event handlers
    notify_event_handlers(client, "endpoint", data)
  end

  defp handle_sse_event(client, event_type, data) do
    # Notify any registered event handlers
    notify_event_handlers(client, event_type, data)
  end

  @spec handle_message(client(), map()) :: :ok
  defp handle_message(client, %{"method" => method, "params" => params}) do
    # Handle notifications
    Logger.debug("Received notification: #{method}")
    notify_event_handlers(client, "notification", %{method: method, params: params})
  end

  defp handle_message(client, %{"id" => id} = message) do
    # Handle responses to requests
    case Agent.get_and_update(client, fn state ->
           case Map.pop(state.requests, id) do
             {nil, state} -> {{:error, :unknown_request}, state}
             {request, new_requests} -> {request, %{state | requests: new_requests}}
           end
         end) do
      {:error, :unknown_request} ->
        Logger.warning("Received response for unknown request ID: #{id}")

      {from, _request_data} ->
        # Send the response to the waiting process
        if is_pid(from) and Process.alive?(from) do
          if Map.has_key?(message, "result") do
            send(from, {:response, {:ok, message["result"]}})
          else
            send(from, {:response, {:error, message["error"]}})
          end
        end
    end
  end

  defp handle_message(_client, message) do
    Logger.warning("Received unexpected message: #{inspect(message)}")
  end

  @spec notify_event_handlers(client(), String.t(), map() | binary()) :: :ok
  defp notify_event_handlers(client, event_type, data) do
    # Get any registered handlers for this event type
    handlers =
      Agent.get(client, fn state ->
        Map.get(state.event_handlers, event_type, [])
      end)

    # Call each handler with the event data
    Enum.each(handlers, fn handler ->
      try do
        handler.(data, client)
      rescue
        e ->
          Logger.error("Error in event handler for #{event_type}: #{inspect(e)}")
      end
    end)
  end

  @spec send_request(client(), String.t(), map(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  defp send_request(client, method, params, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Get the client state
    {request_id, message_endpoint, session_id} =
      Agent.get_and_update(client, fn state ->
        request_id = state.request_id_counter

        {{request_id, state.message_endpoint, state.session_id},
         %{state | request_id_counter: request_id + 1}}
      end)

    # Ensure we have a message endpoint
    unless message_endpoint do
      return_error("No message endpoint available")
    end

    # Build the request
    request = %{
      jsonrpc: "2.0",
      id: request_id,
      method: method,
      params: params
    }

    # Register the request in the state
    Agent.update(client, fn state ->
      %{
        state
        | requests:
            Map.put(state.requests, request_id, {self(), %{method: method, params: params}})
      }
    end)

    # Build the URL with session ID
    url =
      if String.contains?(message_endpoint, "?"),
        do: "#{message_endpoint}&sessionId=#{session_id}",
        else: "#{message_endpoint}?sessionId=#{session_id}"

    # Send the request using Finch
    headers = [{"content-type", "application/json"}]
    body = Jason.encode!(request)

    Logger.debug("Sending request: #{method} #{inspect(params)}")

    req = Finch.build(:post, url, headers, body)
    finch_options = [receive_timeout: timeout]

    case Finch.request(req, MCP.Finch, finch_options) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, response} ->
            if Map.has_key?(response, "result") do
              {:ok, response["result"]}
            else
              {:error, response["error"]}
            end

          {:error, reason} ->
            return_error("Invalid JSON response: #{inspect(reason)}")
        end

      {:ok, %Finch.Response{status: status}} ->
        return_error("HTTP error: #{status}")

      {:error, reason} ->
        return_error("Request failed: #{inspect(reason)}")
    end
  end

  @spec wait_for_message_endpoint(client(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  defp wait_for_message_endpoint(client, timeout) do
    if Agent.get(client, fn state -> state.message_endpoint end) do
      {:ok, Agent.get(client, & &1)}
    else
      # Wait for a short time to see if the message endpoint gets set
      # This is done in chunks to allow for termination
      # milliseconds
      endpoint_check_interval = 100
      wait_time = 0

      wait_for_endpoint_loop(client, wait_time, timeout, endpoint_check_interval)
    end
  end

  @spec wait_for_endpoint_loop(client(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  defp wait_for_endpoint_loop(client, wait_time, timeout, interval) do
    cond do
      wait_time >= timeout ->
        {:error, :timeout}

      Agent.get(client, fn state -> state.message_endpoint end) ->
        {:ok, Agent.get(client, & &1)}

      true ->
        Process.sleep(interval)
        wait_for_endpoint_loop(client, wait_time + interval, timeout, interval)
    end
  end

  @spec add_session_id(String.t(), String.t()) :: String.t()
  defp add_session_id(url, session_id) do
    uri = URI.parse(url)
    query = uri.query || ""

    new_query =
      if query == "" do
        "sessionId=#{session_id}"
      else
        "#{query}&sessionId=#{session_id}"
      end

    %{uri | query: new_query} |> URI.to_string()
  end

  @spec add_param_if_present(map(), atom(), any()) :: map()
  defp add_param_if_present(map, _key, nil), do: map
  defp add_param_if_present(map, key, value), do: Map.put(map, key, value)

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @spec return_error(String.t()) :: {:error, String.t()}
  defp return_error(message) do
    Logger.error(message)
    {:error, message}
  end
end
