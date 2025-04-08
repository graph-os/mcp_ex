defmodule MCP.Endpoint do
  @moduledoc """
  A reusable MCP server endpoint.

  This module provides a complete, ready-to-use MCP server endpoint that can be
  included in other applications. It uses the MCP.DefaultServer implementation
  by default, but can be configured to use a custom server.

  ## Example

      # In your application supervision tree
      children = [
        {MCP.Endpoint,
          server: MyApp.CustomMCPServer,
          port: 4000,
          mode: :debug
        }
      ]

  ## Options

  * `:server` - The MCP server module to use (default: MCP.DefaultServer)
  * `:port` - The port to listen on (default: 4000)
  * `:mode` - The mode to use (`:sse`, `:debug`, or `:inspect`) (default: `:sse`)
  * `:host` - The host to bind to (default: "0.0.0.0")
  * `:path_prefix` - The URL path prefix for MCP endpoints (default: "/mcp")
  """

  use Supervisor
  require Logger

  @doc """
  Starts the MCP server endpoint.

  ## Options

  * `:server` - The MCP server module to use (default: MCP.EchoServer)
  * `:port` - The port to listen on (default: 4004)
  * `:mode` - The mode to use (`:sse`, `:debug`, or `:inspect`) (default: `:sse`)
  * `:host` - The host to bind to (default: "localhost" for better security)
  * `:path_prefix` - The URL path prefix for MCP endpoints (default: "/mcp")

  ## Security Note

  For security reasons, the default binding is set to "localhost" (127.0.0.1),
  which only allows connections from the local machine. If you need to allow
  remote connections, you can set `:host` to "0.0.0.0", but be aware that
  this opens the server to all network interfaces and should be used with caution.
  """
  def start_link(opts \\ []) do
    server = Keyword.get(opts, :server, MCP.EchoServer)
    port = Keyword.get(opts, :port, 4004)
    mode = Keyword.get(opts, :mode, :sse)
    host = Keyword.get(opts, :host, "localhost")
    path_prefix = Keyword.get(opts, :path_prefix, "")

    # Store configuration for the router
    Application.put_env(:mcp, :endpoint, %{
      server: server,
      mode: mode,
      path_prefix: path_prefix
    })

    Supervisor.start_link(__MODULE__, {port, host}, name: __MODULE__)
  end

  @impl true
  def init({port, host}) do
    config = Application.get_env(:mcp, :endpoint)
    path_prefix = config.path_prefix

    # Configure Bandit options
    opts = [
      port: port,
      ip: parse_host(host),
      # Specify the plug directly
      plug: {MCP.Router, []}
    ]

    children = [
      # Start Bandit directly
      {Bandit, opts}
    ]

    # Use inspect(host) to handle both string and IP tuple representations
    Logger.info("MCP Endpoint starting with Bandit on #{inspect(host)}:#{port}#{path_prefix} in #{config.mode} mode")

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Parse a host string into an IP tuple
  defp parse_host(host) do
    case host do
      "localhost" -> {127, 0, 0, 1}
      "0.0.0.0" -> {0, 0, 0, 0}
      h when is_binary(h) ->
        h
        |> String.split(".")
        |> Enum.map(&String.to_integer/1)
        |> List.to_tuple()
      ip when is_tuple(ip) -> ip
    end
  end
end

defmodule MCP.SSEHandler do
  @moduledoc """
  Plug handler for Server-Sent Events (SSE) connections.
  Manages the lifecycle of an SSE connection within the Plug process.
  """
  use Plug.Builder
  require Logger

  # Plug initialization
  def init(opts), do: opts

  def call(conn, _opts) do
    # Ensure this process traps exits to handle cleanup if the client disconnects
    Process.flag(:trap_exit, true)

    session_id = get_session_id(conn)
    Logger.debug("SSE connection request", session_id: session_id)

    # Prepare the connection for SSE streaming
    conn = conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")

    # Register the connection process PID (self()) in the registry using the GenServer
    {:ok, _} = SSE.ConnectionRegistryServer.register(session_id, %{handler_pid: self()})
    Logger.debug("Registered SSE handler process #{inspect self()} for session #{session_id}")

    # Start the MCP server logic for this session (non-blocking)
    config = Application.get_env(:mcp, :endpoint)
    server = config.server
    # Assuming server.start is non-blocking or handles its own process
    server.start(session_id)

    # Send the initial message endpoint URL as the first chunk
    message_endpoint = "/rpc/#{session_id}" # Path relative to host

    # Send initial chunk and then enter loop
    # Send "message" event type according to how tests assert
    case send_sse_event(conn, "message", %{session_id: session_id, message_endpoint: message_endpoint}) do
      {:ok, conn_after_send} ->
        Logger.debug("Sent initial SSE message event for session #{session_id}, entering loop.")
        # Enter the loop to handle subsequent events
        sse_loop(conn_after_send, session_id)
        # sse_loop only returns on error/closure, execution likely ends here.

      {:error, :closed} ->
        Logger.info("SSE connection closed during initial event send for session #{session_id}. Cleaning up.")
        cleanup_sse(session_id)
        halt(conn) # Ensure pipeline stops

      {:error, reason} ->
        Logger.error("Error sending initial SSE event for #{session_id}: #{inspect reason}. Cleaning up.")
        cleanup_sse(session_id)
        # Consider sending a 500 response before halting?
        conn |> send_resp(500, "Internal Server Error") |> halt()
    end

    # If the loop somehow exits cleanly without error (e.g., a specific :stop message),
    # ensure the connection is halted.
    # halt(conn)
    # However, sse_loop as defined will block indefinitely or terminate the process.
  end

  # Receive loop for handling SSE events for a connection
  defp sse_loop(conn, session_id) do
    receive do
      # Message from MCP Server to send to client
      {:sse_event, event_type, data} ->
        Logger.debug("[SSE Handler #{session_id}] Received event: #{event_type}")
        case send_sse_event(conn, event_type, data) do
          {:ok, new_conn} ->
            sse_loop(new_conn, session_id) # Loop with the *new* connection state
          {:error, :closed} ->
            Logger.info("[SSE Handler #{session_id}] Connection closed by client. Cleaning up.")
            cleanup_sse(session_id)
            # Process terminates here, halting implicitly
          {:error, reason} ->
            Logger.error("[SSE Handler #{session_id}] Error sending chunk: #{inspect(reason)}. Cleaning up.")
            cleanup_sse(session_id)
            # Process terminates here, halting implicitly
        end

      # Message indicating the underlying socket/connection has closed (from trapped EXIT)
      {:EXIT, _pid, reason} ->
        # Ignore :normal exits, log others
        unless reason == :normal do
           Logger.info("[SSE Handler #{session_id}] Plug process received EXIT: #{inspect(reason)}. Assuming client disconnected. Cleaning up.")
        end
        cleanup_sse(session_id)
        # Process terminates here

      # Add handling for other potential messages if needed (e.g., stop commands)
      unknown_message ->
         Logger.warning("[SSE Handler #{session_id}] Received unknown message: #{inspect unknown_message}")
         sse_loop(conn, session_id) # Continue loop with old conn state
    end
  end

  # Helper to send a single SSE event chunk
  defp send_sse_event(conn, event_type, data) do
    event_payload = "event: #{event_type}\ndata: #{Jason.encode!(data)}\n\n"
    conn_after_chunked =
      if conn.state == :set do
        # First chunk, call send_chunked first. It returns the conn on success.
        # If it fails (e.g., connection closed prematurely), it raises/exits.
        Plug.Conn.send_chunked(conn, 200)
      else
        # Response already started, just use the existing conn
        conn
      end

    # send_chunked raises on error, so we can assume conn_after_chunked is valid
    # chunk also returns {:ok, conn} or {:error, reason}
    Plug.Conn.chunk(conn_after_chunked, event_payload)
  end

  # Cleanup SSE session resources
  defp cleanup_sse(session_id) do
    Logger.debug("[SSE Handler #{session_id}] Cleaning up SSE connection.")
    # Use GenServer unregister
    SSE.ConnectionRegistryServer.unregister(session_id)
    # Optionally tell the MCP server logic to stop if needed
    # config = Application.get_env(:mcp, :endpoint)
    # server = config.server
    # if function_exported?(server, :stop, 1), do: server.stop(session_id)
  end

  # Get the session ID from the Plug connection query parameters
  defp get_session_id(conn) do
    case conn.query_params["sessionId"] do
      nil -> UUID.uuid4()
      session_id -> session_id
    end
  end
end
