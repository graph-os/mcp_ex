defmodule MCP.Router do
  @moduledoc """
  Router for the MCP server.

  This module defines routes for the MCP server with configurable modes:
  - :sse - Only SSE connection endpoint
  - :debug - SSE endpoint with JSON/API debugging
  - :inspect - Full HTML/JS endpoints with all of the above
  """

  use Plug.Router

  require Logger

  # Plugs
  plug Plug.Logger
  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch

  # Helper to get mode directly from config
  defp get_current_mode do
    config = Application.get_env(:mcp, :endpoint, %{mode: :sse}) # Default to :sse
    config.mode
  end

  # Helper to check mode directly from config
  defp should_handle_route?(allowed_modes) do
    get_current_mode() in allowed_modes
  end

  # SSE connection endpoint (available in all modes - no mode check needed here)
  get "/sse" do
    session_id = UUID.uuid4()
    Logger.info("New SSE connection", session_id: session_id)

    # Fetch path prefix from config to construct correct RPC endpoint
    config = Application.get_env(:mcp, :endpoint, %{path_prefix: ""})
    path_prefix = config.path_prefix # Already normalized by MCP.Endpoint

    # Return the session ID and message endpoint (with prefix) in the initial SSE event
    initial_data = %{
      session_id: session_id,
      message_endpoint: "#{path_prefix}/rpc/#{session_id}"
    }

    # Handle the SSE connection
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> send_sse_data_and_loop(session_id, initial_data)
  end

  # Simple ping route
  get "/ping" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "pong")
  end

  # Root path returns mode information - useful for checking server status
  get "/" do
    mode = get_current_mode()
    response = %{
      status: "ok",
      mode: mode,
      server: "MCP Server",
      version: "0.1.0"
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  # The following routes are only available in :debug and :inspect modes

  # JSON-RPC request endpoint (without session ID)
  post "/rpc" do
    # Check mode directly
    if should_handle_route?([:debug, :inspect]) do
      conn = fetch_query_params(conn)
      session_id = conn.query_params["session_id"]

      if session_id do
        handle_rpc_request(conn, session_id)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Missing session_id parameter"}))
      end
    else
      not_found(conn)
    end
  end

  # JSON-RPC request endpoint (with session ID in path)
  post "/rpc/:session_id" do
    # Check mode directly
    if should_handle_route?([:debug, :inspect]) do
      handle_rpc_request(conn, session_id)
    else
      not_found(conn)
    end
  end

  # Debug information for a specific session
  get "/debug/:session_id" do
    # Check mode directly
    if should_handle_route?([:debug, :inspect]) do
      # Use GenServer lookup
      case SSE.ConnectionRegistryServer.lookup(session_id) do
        {:ok, data} -> # GenServer lookup returns {:ok, data} directly
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{
            session_id: session_id,
            session_data: redact_sensitive_data(data)
          }))

        {:error, :not_found} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{error: "Session not found"}))
      end
    else
      not_found(conn)
    end
  end

  # List active sessions
  get "/debug/sessions" do
    # Check mode directly
    if should_handle_route?([:debug, :inspect]) do
      # Get sessions from GenServer using the list_sessions function
      session_map = SSE.ConnectionRegistryServer.list_sessions() # Returns %{session_id => data}
      sessions = Map.keys(session_map)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{sessions: sessions}))
    else
      not_found(conn)
    end
  end

  # JSON API description
  get "/debug/api" do
    # Check mode directly
    if should_handle_route?([:debug, :inspect]) do
      # Build the API endpoints based on the current mode
      current_mode = get_current_mode()
      endpoints = [
        %{
          path: "/",
          method: "GET",
          description: "Returns server status and mode information"
        },
        %{
          path: "/sse",
          method: "GET",
          description: "Establishes a Server-Sent Events (SSE) connection to the MCP server"
        },
        %{
          path: "/rpc",
          method: "POST",
          description: "Sends a JSON-RPC request to the MCP server (requires session_id query parameter)"
        },
        %{
          path: "/rpc/:session_id",
          method: "POST",
          description: "Sends a JSON-RPC request to the MCP server for a specific session"
        },
        %{
          path: "/debug/:session_id",
          method: "GET",
          description: "Returns debugging information about a specific session"
        },
        %{
          path: "/debug/sessions",
          method: "GET",
          description: "Lists all active sessions"
        },
        %{
          path: "/debug/api",
          method: "GET",
          description: "Returns this API description"
        }
      ]

      # Add inspector endpoints if in inspect mode
      endpoints = if current_mode == :inspect do
        endpoints ++ [
          %{
            path: "/inspector",
            method: "GET",
            description: "Provides a web interface for inspecting and debugging MCP protocol messages"
          },
          %{
            path: "/debug/tool/:tool_name",
            method: "GET",
            description: "Provides a web interface for testing a specific tool"
          }
        ]
      else
        endpoints
      end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{
        endpoints: endpoints,
        mode: current_mode
      }))
    else
      not_found(conn)
    end
  end

  # The following routes are only available in :inspect mode

  # MCP Inspector UI
  get "/inspector" do
    # Check mode directly
    if should_handle_route?([:inspect]) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, inspector_html())
    else
      not_found(conn)
    end
  end

  # Debug UI for testing tools
  get "/debug/tool/:tool_name" do
    # Check mode directly
    if should_handle_route?([:inspect]) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, debug_tool_html(tool_name))
    else
      not_found(conn)
    end
  end

  # Catch-all route
  match _ do
    not_found(conn)
  end

  # Private functions

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end

  defp handle_rpc_request(conn, session_id) do
    # Fetch the configured server implementation
    config = Application.get_env(:mcp, :endpoint)
    server_impl = config.server || MCP.DefaultServer # Use configured or default

    # Try to get body from Plug.Parsers first, otherwise read it manually
    body_or_params = if conn.body_params == %{} or conn.body_params == nil do
      # Body wasn't parsed by Plug.Parsers or is empty, try reading
      case Plug.Conn.read_body(conn) do
        {:ok, body, _conn} -> body
        {:error, _} -> "" # Default to empty string on read error
      end
    else
      # Body was parsed successfully by Plug.Parsers
      conn.body_params
    end

    # Parse the JSON-RPC request (handle both string body and pre-parsed map)
    case decode_rpc_request(body_or_params) do
      {:ok, request} ->
        # Dispatch the request using MCP.Dispatcher
      case MCP.Dispatcher.handle_request(server_impl, session_id, request) do
        # Case 1: Dispatcher handled response via SSE (returned empty map)
        {:ok, %{}} ->
          Logger.debug("Dispatcher handled response via SSE for request ID #{request["id"]}. Sending minimal HTTP 200 OK.")
          conn
          |> put_resp_content_type("application/json")
          # Send minimal success response, client ignores this body anyway
          |> send_resp(200, Jason.encode!(%{status: "ok"}))

        # Case 2: Dispatcher returned a specific map for the HTTP response
        {:ok, response_map} when is_map(response_map) and map_size(response_map) > 0 ->
          Logger.debug("Dispatcher returned HTTP response for request ID #{request["id"]}: #{inspect response_map}")
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response_map))

        # Case 3: Dispatcher returned an error (which should now be sent via SSE by the dispatcher itself)
        {:error, {code, message, _data} = reason} ->
          Logger.debug("Dispatcher returned error tuple for request ID #{request["id"]}: #{code} - #{message}. Assuming error sent via SSE. Sending minimal HTTP 200 OK.")
          # Check if the dispatcher actually handled sending the error via SSE
          # (We assume it did based on the dispatcher logic for tools/list error path)
          # If the dispatcher *didn't* send via SSE (e.g., for other methods not yet updated),
          # the client won't get the error. This needs to be handled consistently.
          # For now, proceed assuming the dispatcher sent the error via SSE.
          conn
          |> put_resp_content_type("application/json")
          # Send minimal success response, client ignores this body anyway
          |> send_resp(200, Jason.encode!(%{status: "ok", note: "Error handled via SSE"}))
        end

      {:error, reason} ->
        # Invalid JSON
        Logger.error("RPC Parse error for session #{session_id}: #{inspect(reason)}")
        # Build parse error map directly
        error_response = %{
          jsonrpc: "2.0",
          id: nil,
          error: %{
            code: -32700, # Use @parse_error if defined
            message: "Parse error",
            data: %{reason: inspect(reason)}
          }
        }
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(error_response))
    end
  end

  # Helper to decode request from either string or map
  defp decode_rpc_request(params) when is_map(params) do
    # Already decoded by Plug.Parsers
    {:ok, params}
  end
  defp decode_rpc_request(body) when is_binary(body) do
    # Decode from raw string body
    Jason.decode(body)
  end
  defp decode_rpc_request(_) do
    # Invalid input type
    {:error, :invalid_input_type}
  end

  defp redact_sensitive_data(data) do
    # Remove sensitive data from the session data
    # In a real implementation, you would redact sensitive data
    data
  end

  defp inspector_html do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>MCP Inspector</title>
      <style>
        body {
          font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          max-width: 800px;
          margin: 0 auto;
          padding: 20px;
        }
        h1, h2 { color: #333; }
        .container {
          display: flex;
          flex-direction: column;
          height: 100vh;
        }
        #inspector-container {
          flex-grow: 1;
          margin-top: 20px;
          border: 1px solid #ddd;
          border-radius: 4px;
          min-height: 500px;
        }
        .info {
          background-color: #f0f8ff;
          padding: 12px;
          border-radius: 4px;
          margin-bottom: 16px;
        }
        pre { background: #f5f5f5; padding: 10px; border-radius: 4px; }
        button { padding: 8px 16px; background: #4CAF50; color: white; border: none; border-radius: 4px; cursor: pointer; margin-top: 10px; }
        button:hover { background: #45a049; }
        input { width: 100%; padding: 8px; margin: 8px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>MCP Inspector</h1>

        <div class="info">
          <p>This page embeds the MCP Inspector to debug MCP protocol messages.</p>
          <p>Connection URL: <code id="connection-url">http://localhost:4004/sse</code></p>
        </div>

        <div id="connection-form">
          <h2>Connection Settings</h2>
          <label for="sse-url">SSE Endpoint URL:</label>
          <input type="text" id="sse-url" value="/sse">
          <button id="load-inspector">Load Inspector</button>
        </div>

        <div id="inspector-container"></div>
      </div>

      <script>
        document.getElementById('load-inspector').addEventListener('click', () => {
          const sseUrl = document.getElementById('sse-url').value;
          loadInspector(sseUrl);
        });

        function loadInspector(sseUrl) {
          // Update the display URL
          document.getElementById('connection-url').textContent = new URL(sseUrl, window.location.origin).href;

          // Create a script element to load the MCP Inspector
          const script = document.createElement('script');
          script.src = 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/inspector@latest/dist/index.js';
          script.onload = () => {
            const container = document.getElementById('inspector-container');

            // Clear previous content
            container.innerHTML = '';

            // Check if the MCPInspector global is available
            if (window.MCPInspector) {
              try {
                // Configure the inspector to use our SSE URL
                const inspector = new window.MCPInspector({
                  container: container,
                  serverUrl: sseUrl
                });

                // Start the inspector
                inspector.start();
              } catch (error) {
                container.innerHTML = `<div class="error">Error initializing MCP Inspector: ${error.message}</div>`;
              }
            } else {
              container.innerHTML = '<div class="error">MCP Inspector failed to load. Check console for errors.</div>';
            }
          };

          script.onerror = () => {
            document.getElementById('inspector-container').innerHTML =
              '<div class="error">Failed to load MCP Inspector from CDN. Check your internet connection.</div>';
          };

          // Add the script to the document
          document.body.appendChild(script);
        }
      </script>
    </body>
    </html>
    """
  end

  defp debug_tool_html(tool_name) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>MCP Tool Debug - #{tool_name}</title>
      <style>
        body {
          font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          max-width: 800px;
          margin: 0 auto;
          padding: 20px;
        }
        h1 { color: #333; }
        pre { background: #f5f5f5; padding: 10px; border-radius: 4px; }
        button { padding: 8px 16px; background: #4CAF50; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:hover { background: #45a049; }
        input, textarea { width: 100%; padding: 8px; margin: 8px 0; }
        #response { margin-top: 20px; }
      </style>
    </head>
    <body>
      <h1>MCP Tool Debug: #{tool_name}</h1>

      <div>
        <h2>Session Setup</h2>
        <div>
          <label for="session-id">Session ID:</label>
          <input type="text" id="session-id" placeholder="Enter session ID or leave empty to create new">
          <button id="connect">Connect</button>
        </div>
      </div>

      <div>
        <h2>Tool Parameters</h2>
        <div>
          <label for="tool-params">Parameters (JSON):</label>
          <textarea id="tool-params" rows="5">{"key": "value"}</textarea>
        </div>
        <button id="call-tool">Call Tool</button>
      </div>

      <div id="response">
        <h2>Response</h2>
        <pre id="response-data">No response yet</pre>
      </div>

      <script>
        let sessionId = '';
        let eventSource = null;

        document.getElementById('connect').addEventListener('click', () => {
          const inputSessionId = document.getElementById('session-id').value.trim();

          if (eventSource) {
            eventSource.close();
          }

          // Create SSE connection
          const url = inputSessionId ? `/sse?session_id=${inputSessionId}` : '/sse';
          eventSource = new EventSource(url);

          eventSource.onopen = () => {
            console.log('SSE connection opened');
          };

          eventSource.addEventListener('message', (event) => {
            const data = JSON.parse(event.data);
            console.log('SSE message:', data);

            if (data.session_id) {
              sessionId = data.session_id;
              document.getElementById('session-id').value = sessionId;
            }

            document.getElementById('response-data').textContent = JSON.stringify(data, null, 2);
          });

          eventSource.onerror = (error) => {
            console.error('SSE error:', error);
            document.getElementById('response-data').textContent = 'SSE connection error';
          };
        });

        document.getElementById('call-tool').addEventListener('click', async () => {
          if (!sessionId) {
            alert('Please connect to a session first');
            return;
          }

          try {
            const params = JSON.parse(document.getElementById('tool-params').value);

            const request = {
              jsonrpc: "2.0",
              method: "callTool",
              params: {
                name: "#{tool_name}",
                arguments: params
              },
              id: Date.now().toString()
            };

            const response = await fetch(`/rpc/${sessionId}`, {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json'
              },
              body: JSON.stringify(request)
            });

            const responseData = await response.json();
            document.getElementById('response-data').textContent = JSON.stringify(responseData, null, 2);
          } catch (error) {
            document.getElementById('response-data').textContent = `Error: ${error.message}`;
          }
        });
      </script>
    </body>
    </html>
    """
  end

  # Helper function for SSE connections - Renamed and modified
  defp send_sse_data_and_loop(conn, session_id, initial_data) do
    # Register this connection in the registry
    initial_registry_data = %{
      handler_pid: self(),
      plug_pid: conn.owner
    }
    # Use GenServer register, explicitly passing the server name
    # Expect :ok on success from GenServer.call
    :ok = SSE.ConnectionRegistryServer.register(SSE.ConnectionRegistryServer, session_id, initial_registry_data)

    # Update registry with MCP data (consider if this should happen only on initialize)
    mcp_initial_data = %{
      protocol_version: nil,
      capabilities: %{},
      initialized: false,
      tools: %{}
    }
    # Use GenServer update, explicitly passing the server name
    SSE.ConnectionRegistryServer.update_data(SSE.ConnectionRegistryServer, session_id, mcp_initial_data)

    # Send the initial data as the *endpoint* event
    endpoint_url = initial_data.message_endpoint # Extract just the URL path
    # Construct full URL? Client seems to expect just the path based on event name?
    # Let's send just the path for now.
    case chunk(conn, "event: endpoint\ndata: #{endpoint_url}\n\n") do
      {:ok, conn_after_chunk} ->
        Logger.debug("[SSE Handler #{session_id}] Initial endpoint event sent successfully.")
        # Add small delay before starting loop, maybe chunk is async?
        Process.sleep(50)
        # Enter receive loop after sending initial endpoint event
        sse_loop(conn_after_chunk, session_id)
      {:error, reason} ->
        Logger.error("[SSE Handler #{session_id}] Error sending initial endpoint event: #{inspect(reason)}. Cleaning up.")
        cleanup_sse(session_id)
        # Let Plug/Bandit handle the connection termination after error
        # reraise reason, __STACKTRACE__ # Cannot reraise here
    end
  end

  # Basic SSE receive loop (adapted from MCP.SSEHandler concept)
  defp sse_loop(conn, session_id) do
    Logger.debug("[SSE Loop #{session_id}] Waiting for message...")
    receive do
      {:sse_event, event_type, data} = msg -> # Log the whole message
        Logger.debug("[SSE Loop #{session_id}] Received message: #{inspect msg}")
        case send_sse_event(conn, event_type, data) do
          {:ok, new_conn} ->
            sse_loop(new_conn, session_id) # Loop with the *new* connection state
          {:error, :closed} ->
            Logger.info("[SSE Loop #{session_id}] Connection closed by client during send. Cleaning up.")
            cleanup_sse(session_id)
            # Connection closed, exit loop implicitly
          {:error, reason} ->
            Logger.error("[SSE Loop #{session_id}] Error sending chunk: #{inspect(reason)}. Cleaning up.")
            cleanup_sse(session_id)
            # Exit loop implicitly on error
        end

      # --- BEGIN ADDED CODE ---
      # Handle standard JSON-RPC messages sent over the stream
      {:sse_message, data} = msg ->
        Logger.debug("[SSE Loop #{session_id}] Received message: #{inspect msg}")
        case send_sse_message(conn, data) do
          {:ok, new_conn} ->
            sse_loop(new_conn, session_id) # Loop with the *new* connection state
          {:error, :closed} ->
            Logger.info("[SSE Loop #{session_id}] Connection closed by client during send. Cleaning up.")
            cleanup_sse(session_id)
          {:error, reason} ->
            Logger.error("[SSE Loop #{session_id}] Error sending chunk: #{inspect(reason)}. Cleaning up.")
            cleanup_sse(session_id)
        end
      # --- END ADDED CODE ---

      # Add EXIT handling if Process.flag(:trap_exit, true) is set earlier
      # {:EXIT, _pid, reason} -> ... cleanup_sse(session_id) ...

      # Add other control messages if needed (e.g., :stop)

      unknown_message ->
         Logger.warning("[SSE Loop #{session_id}] Received unknown message: #{inspect unknown_message}")
         sse_loop(conn, session_id) # Continue loop
    after
      # Add a timeout? Maybe Application config? Default: infinity (like Process.sleep)
      :infinity ->
        sse_loop(conn, session_id) # Keep loop alive
    end
  end

  # Helper to send a single SSE event chunk (with event type)
  defp send_sse_event(conn, event_type, data) do
      event_payload = "event: #{event_type}\ndata: #{Jason.encode!(data)}\n\n"
      Plug.Conn.chunk(conn, event_payload)
  end

  # --- BEGIN ADDED CODE ---
  # Helper to send a standard SSE message chunk (without event type)
  defp send_sse_message(conn, data) do
    message_payload = "data: #{Jason.encode!(data)}\n\n"
    Plug.Conn.chunk(conn, message_payload)
  end
  # --- END ADDED CODE ---

  # Cleanup SSE session resources
  defp cleanup_sse(session_id) do
    Logger.debug("[SSE Cleanup #{session_id}] Cleaning up SSE connection.")
    # Use GenServer unregister
    SSE.ConnectionRegistryServer.unregister(session_id)
    # Optional: Tell MCP server logic to stop if needed
  end
end
