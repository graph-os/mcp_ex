defmodule SSE.ConnectionPlug do
  @moduledoc """
  Plug for handling SSE connections and JSON-RPC message requests.

  Handles the initial GET request to establish the SSE stream and start a
  connection handler process. Forwards subsequent POST requests to the handler.
  """

  use Plug.Builder
  import Plug.Conn
  require Logger

  # --- Plugs ---

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  # --- Plug Callbacks ---

  def init(opts), do: opts

  # Handles initial GET /sse request
  def call(%{method: "GET"} = conn, _opts) do
    session_id = UUID.uuid4()
    Logger.debug("[SSE.ConnectionPlug GET] New connection attempt", session_id: session_id)
    handle_sse_connection(conn, session_id)
  end

  # Handles POST /rpc/:session_id forwarded from the main router
  def call(%{method: "POST", path_params: %{"session_id" => session_id}} = conn, _opts) do
    Logger.debug("[SSE.ConnectionPlug POST] Received POST request for session: #{session_id}")
    handle_message_request(conn, session_id)
  end

  # Fallback for other methods
  def call(conn, _opts) do
    send_resp(conn, 405, "Method Not Allowed")
  end

  # --- Private Functions ---

  defp handle_sse_connection(conn, session_id) do
    Logger.debug("[SSE.ConnectionPlug GET] Preparing SSE connection", session_id: session_id)
    # 1. Set headers and start chunked response *from the plug process*
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Initial endpoint event is now sent by the ConnectionHandler itself.

    # 3. Start the ConnectionHandler GenServer under the DynamicSupervisor, passing plug_pid
    Logger.debug("[SSE.ConnectionPlug GET] Attempting to start ConnectionHandler under DynamicSupervisor for session #{session_id}, passing plug_pid #{inspect self()}")
    child_spec = {SSE.ConnectionHandler, %{session_id: session_id, plug_pid: self()}}
    case DynamicSupervisor.start_child(MCP.SSE.ConnectionSupervisor, child_spec) do
      {:ok, handler_pid} ->
        Logger.debug("[SSE.ConnectionPlug GET] Started ConnectionHandler #{inspect handler_pid} under DynamicSupervisor for session #{session_id}")

        # Registration is handled by the ConnectionHandler in init/1
        # Keep plug process alive
        Logger.debug("[SSE.ConnectionPlug GET] Entering plug_receive_loop for session #{session_id}")
        plug_receive_loop(conn, session_id) # Pass session_id

      {:error, {:already_started, _pid}} ->
         Logger.warning("[SSE.ConnectionPlug GET] ConnectionHandler GenServer already started for session #{session_id}")
         send_resp(conn, 500, "Session handler process already exists") # Use original conn

      {:error, reason} ->
        Logger.error("[SSE.ConnectionPlug GET] Failed to start ConnectionHandler GenServer for session #{session_id}: #{inspect reason}")
        send_resp(conn, 500, "Internal Server Error starting session handler") # Use original conn
    end
  end

  # Loop to keep the plug process alive and send chunks requested by the handler
  # Revert: Receives session_id
  defp plug_receive_loop(conn, session_id) do
    # Revert: Lookup handler_pid using session_id
    handler_pid =
      case SSE.ConnectionRegistry.lookup(session_id) do
        {:ok, %{handler_pid: pid}} -> pid
        _ ->
          Logger.error("[SSE.ConnectionPlug GET Loop] Could not find handler_pid in registry for session #{session_id}. Exiting loop.")
          nil
      end

    if handler_pid && Process.alive?(handler_pid) do
      # Monitor the handler process
      ref = Process.monitor(handler_pid)
      Logger.debug("[SSE.ConnectionPlug GET Loop] Monitoring handler #{inspect handler_pid} with ref #{inspect ref} for session #{session_id}")

      receive do
        {:send_chunk, chunk_data} ->
          Logger.debug("[SSE.ConnectionPlug GET Loop] Received :send_chunk for session #{session_id}. Chunk: #{inspect chunk_data}")
          # Use Plug.Conn.chunk directly here as well
          case Plug.Conn.chunk(conn, chunk_data) do
            {:ok, new_conn} ->
              Logger.debug("[SSE.ConnectionPlug GET Loop] Successfully sent chunk for session #{session_id}.")
              Process.demonitor(ref, [:flush]) # Demonitor before recursing
              plug_receive_loop(new_conn, session_id) # Pass session_id
            {:error, :closed} ->
              Logger.warning("[SSE.ConnectionPlug GET Loop] Connection closed for session #{session_id} while trying to send chunk.")
              Process.demonitor(ref, [:flush])
              # Handler might still be running, attempt to stop it
              GenServer.stop(handler_pid, :normal)
              conn # Exit loop, returning conn
            {:error, reason} ->
              Logger.error("[SSE.ConnectionPlug GET Loop] Error sending chunk for session #{session_id}: #{inspect reason}")
              Process.demonitor(ref, [:flush])
              plug_receive_loop(conn, session_id) # Continue loop with old conn, pass session_id
          end

        # Explicitly handle the :sent confirmation from Plug.Conn.chunk
        {:plug_conn, :sent} ->
          Logger.debug("[SSE.ConnectionPlug GET Loop] Received :plug_conn :sent ack for session #{session_id}. Continuing loop.") # Optional debug log
          Process.demonitor(ref, [:flush]) # Still need to demonitor before recursing
          plug_receive_loop(conn, session_id) # Continue loop, pass session_id

        # Explicit stop message from the handler (e.g., during its terminate)
        {:stop} ->
          Logger.debug("[SSE.ConnectionPlug GET Loop] Received stop message for session #{session_id}. Terminating loop.")
          Process.demonitor(ref, [:flush])
          conn # Exit the loop, returning conn

        # Handler process terminated
        {:DOWN, ^ref, :process, ^handler_pid, reason} ->
          Logger.warning("[SSE.ConnectionPlug GET Loop] Monitored handler process #{inspect handler_pid} DOWN for session #{session_id}. Reason: #{inspect reason}. Terminating loop.")
          # Connection likely already closed or unusable, just exit loop.
          conn # Exit the loop, returning conn

        other ->
          Logger.warning("[SSE.ConnectionPlug GET Loop] Plug process received unexpected message for session #{session_id}: #{inspect other}")
          Process.demonitor(ref, [:flush])
          plug_receive_loop(conn, session_id) # Continue loop with old conn, pass session_id
      after
        # Timeout after 5 minutes of inactivity? Helps cleanup lingering processes.
        300_000 ->
          Logger.warning("[SSE.ConnectionPlug GET Loop] Plug process timing out due to inactivity for session #{session_id}.")
          Process.demonitor(ref, [:flush])
          # Attempt to stop the associated handler
          GenServer.stop(handler_pid, :timeout)
          conn # Exit loop, returning conn
      end # Closes receive
    else
      # handler_pid lookup failed or process not alive
      conn # Return original conn
    end # Closes if handler_pid
  end # Closes defp plug_receive_loop

  defp handle_message_request(conn, session_id) do
    # Revert: Lookup session data (including handler_pid) using session_id
    case SSE.ConnectionRegistry.lookup(session_id) do
      {:error, :not_found} ->
        # Session doesn't exist - invalid or expired
        Logger.warning("[SSE.ConnectionPlug POST Error] Received request for unknown session ID: #{session_id}")
        error_response = %{jsonrpc: "2.0", error: %{code: -32000, message: "Unknown or expired session ID"}}
        conn
        |> put_resp_header("content-type", "application/json; charset=utf-8")
        |> send_resp(404, Jason.encode!(error_response))

      {:ok, %{handler_pid: handler_pid}} -> # Found the session data, extract handler_pid
        # Session exists, proceed with processing the message
        message = conn.body_params
        Logger.debug("[SSE.ConnectionPlug POST Body Params] Parsed body: #{inspect message}")

        if is_map(message) and map_size(message) > 0 do
          # Get the implementation module from config
          implementation_module = Application.get_env(:mcp, :implementation_module)

          if implementation_module do
            # IMPORTANT: We must process messages ASYNCHRONOUSLY and always respond with 204 No Content
            # per MCP SSE specification. The actual responses are sent over the SSE stream.

            # Check if handler process is still alive before casting
            if Process.alive?(handler_pid) do
                # CRITICAL: Send request to handler for async processing
                GenServer.cast(handler_pid, {:process_message, message})

                # Immediately acknowledge the POST with 204 No Content
                send_resp(conn, 204, "")
            else
                 # Handler process died between lookup and cast
                 Logger.error("[SSE.ConnectionPlug POST Error] Handler #{inspect handler_pid} for session #{session_id} died before processing message.")
                 error_response = %{jsonrpc: "2.0", id: message["id"], error: %{code: -32000, message: "Session expired during request"}}
                 # Cannot send via SSE as handler is gone. Send direct error response.
                 conn
                 |> put_resp_header("content-type", "application/json; charset=utf-8")
                 |> send_resp(500, Jason.encode!(error_response))
            end
          else
            # Handle missing configuration
            Logger.error("[SSE.ConnectionPlug POST Error] :implementation_module not configured for :mcp app.")
            error_response = %{jsonrpc: "2.0", id: message["id"], error: %{code: -32000, message: "Server configuration error: Missing implementation module"}}
            # Try to send error via SSE if possible, otherwise send direct error response
            if Process.alive?(handler_pid) do
               GenServer.cast(handler_pid, {:send_message, error_response})
               send_resp(conn, 204, "") # Acknowledge POST
            else
               conn
               |> put_resp_header("content-type", "application/json; charset=utf-8")
               |> send_resp(500, Jason.encode!(error_response))
            end
          end
        else
          # Handle cases where Plug.Parsers failed or body was empty/invalid
          error_response = %{jsonrpc: "2.0", error: %{code: -32700, message: "Parse error: Invalid or empty JSON body"}}
          Logger.warning("[SSE.ConnectionPlug POST Error] Invalid or empty JSON body received for session #{session_id}", body_params: inspect(conn.body_params))
          # Try to send error via SSE if possible, otherwise send direct error response
          if Process.alive?(handler_pid) do
             GenServer.cast(handler_pid, {:send_message, error_response})
             send_resp(conn, 204, "") # Acknowledge POST
          else
             conn
             |> put_resp_header("content-type", "application/json; charset=utf-8")
             |> send_resp(400, Jason.encode!(error_response)) # 400 Bad Request
          end
        end
    end # End of case Registry.lookup...
  end # End of defp handle_message_request...
end # End of defmodule SSE.ConnectionPlug

# --- Connection Handler GenServer ---
defmodule SSE.ConnectionHandler do
  @moduledoc """
  GenServer to manage a single SSE connection state and process messages.
  """
  use GenServer
  require Logger

  # --- Client API ---

  def start_link(args) do
    # Start as a normal GenServer, registration is handled by the Plug
    GenServer.start_link(__MODULE__, args)
  end

  # via_tuple is removed as we don't register the handler by name anymore

  @doc "Sends a JSON-RPC message object over the SSE connection."
  def send_sse_message(session_id, message) do
    # Look up the handler_pid from the registry data and cast to it
    case Registry.lookup(MCP.SSE.ConnectionRegistry, session_id) do
      [{_key, %{handler_pid: handler_pid}}] ->
        GenServer.cast(handler_pid, {:send_message, message})
      [] ->
         Logger.error("[API] Could not find registry entry for session #{session_id} when sending message.")
         {:error, :not_found}
      other ->
         Logger.error("[API] Unexpected registry lookup result for session #{session_id} when sending message: #{inspect other}")
         {:error, :unexpected_registry_result}
    end
  end

  @doc "Sends a raw SSE event chunk over the connection."
  def send_sse_chunk(session_id, chunk) do
     # Look up the handler_pid from the registry data and cast to it
     case Registry.lookup(MCP.SSE.ConnectionRegistry, session_id) do
       [{_key, %{handler_pid: handler_pid}}] ->
         GenServer.cast(handler_pid, {:send_chunk, chunk})
       [] ->
         Logger.error("[API] Could not find registry entry for session #{session_id} when sending chunk.")
         {:error, :not_found}
       other ->
         Logger.error("[API] Unexpected registry lookup result for session #{session_id} when sending chunk: #{inspect other}")
         {:error, :unexpected_registry_result}
     end
  end

  # --- GenServer Callbacks ---

  # Helper for tests to retrieve the session ID
  @impl true
  def handle_call(:get_session_id, _from, state) do
   {:reply, state.session_id, state}
  end

  # Removed handle_call({:set_plug_pid, ...})

  @impl true
  def init(%{session_id: session_id, plug_pid: plug_pid}) do
    Logger.debug("[Handler #{session_id}] Initializing with plug_pid: #{inspect plug_pid}")

    # Register this session with the registry
    initial_data = %{plug_pid: plug_pid, handler_pid: self(), initialized: false} # Add initialized flag
    case SSE.ConnectionRegistry.register(session_id, initial_data) do
      {:ok, _} ->
        Logger.debug("[Handler #{session_id}] Successfully registered session in ConnectionRegistry.")
        # Send the initial endpoint event asynchronously
        GenServer.cast(self(), :send_initial_endpoint)
        # Store session ID and plug_pid in handler state
        {:ok, %{session_id: session_id, plug_pid: plug_pid}}
      {:error, reason} ->
        Logger.error("[Handler #{session_id}] Failed to register session in ConnectionRegistry: #{inspect reason}")
        {:stop, {:failed_to_register, reason}}
    end
  end

  @impl true
  def handle_cast(:send_initial_endpoint, %{session_id: session_id, plug_pid: plug_pid} = state) do
    Logger.debug("[Handler #{session_id}] Sending initial endpoint event to plug #{inspect plug_pid}")
    message_endpoint = "/rpc/#{session_id}"
    # Use string concatenation for consistency with the message format
    chunk = "event: endpoint\ndata: " <> message_endpoint <> "\n\n"
    send_sse_chunk_internal(plug_pid, chunk)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:process_message, message}, state) do
    Logger.debug("[Handler #{state.session_id}] Received cast to process message: #{inspect message}")
    # Get the actual implementation module (e.g., MyApp.CustomMCPServer)
    implementation_module = Application.get_env(:mcp, :implementation_module)

    if implementation_module do
      # Fetch current session data from registry
      session_data_result = MCP.Server.get_session_data(state.session_id)

      # Process the message using the public dispatch function from MCP.Server
      result =
        case session_data_result do
          {:ok, session_data} ->
            try do
              # Use the new public dispatch function
              MCP.Server.dispatch_request(implementation_module, state.session_id, message, session_data)
            rescue
              e ->
                stacktrace = __STACKTRACE__
                Logger.error("[Handler #{state.session_id}] Exception in dispatch_request: #{inspect e}\n#{Exception.format_stacktrace(stacktrace)}")
                {:error, {-32603, "Internal server error", %{message: inspect(e)}}}
            catch
              kind, reason ->
                Logger.error("[Handler #{state.session_id}] Caught #{kind} in dispatch_request: #{inspect reason}")
                {:error, {-32603, "Internal server error", %{message: "#{kind}: #{inspect(reason)}"}}}
            end
          {:error, :not_found} ->
             Logger.error("[Handler #{state.session_id}] Session data not found in registry before dispatching.")
             # Ensure ID is included in the error tuple passed back
             {:error, {-32000, "Session not found", %{request_id: message["id"]}}} # Pass ID in data
        end

      # --- Process the result ---
      case result do
        {:ok, nil} ->
          # This was a notification that doesn't require a response
          Logger.debug("[Handler #{state.session_id}] Processed notification, no response needed")
          :ok

        {:ok, response} when is_map(response) ->
          # Send the JSON-RPC result back via SSE stream
          Logger.debug("[Handler #{state.session_id}] Sending result via SSE: #{inspect response}")
          send_sse_message_internal(state.plug_pid, response)

        # --- Handle standard error tuple {code, message, data} ---
        # Note: The :not_found case above now also returns this tuple format
        {:error, {code, error_message, data}} ->
          # Check if the original message had an ID (i.e., was a request)
          original_request_id = message["id"]
          if is_nil(original_request_id) do
            # Error originated from a notification. DO NOT send a JSON-RPC error response.
            Logger.warning("[Handler #{state.session_id}] Error processing notification (method: #{message["method"]}): Code=#{code}, Msg=#{error_message}, Data=#{inspect data}. No error response sent.")
            :ok # Do nothing further for notification errors
          else
            # Error originated from a request. Send a proper JSON-RPC error response.
            # Use the original request ID.
            error_response = %{jsonrpc: "2.0", id: original_request_id, error: %{code: code, message: error_message, data: data}}
            Logger.warning("[Handler #{state.session_id}] Error processing request (id: #{original_request_id}): #{inspect error_response}")
            send_sse_message_internal(state.plug_pid, error_response)
          end

        # --- Handle validation errors (list of errors) ---
        # These typically come from the dispatcher/server layer for malformed requests.
        {:error, errors} when is_list(errors) ->
          original_request_id = message["id"]
          if is_nil(original_request_id) do
             # Malformed notification - log but don't respond
             Logger.warning("[Handler #{state.session_id}] Invalid JSON-RPC notification structure: #{inspect errors}")
             :ok
          else
             # Malformed request - send error response
             error_response = %{jsonrpc: "2.0", id: original_request_id, error: %{code: -32600, message: "Invalid Request: #{inspect(errors)}"}} # Use standard Invalid Request code
             Logger.warning("[Handler #{state.session_id}] Invalid JSON-RPC request structure (id: #{original_request_id}): #{inspect error_response}")
             send_sse_message_internal(state.plug_pid, error_response)
          end

         # Catch-all for other unexpected errors or return values from handle_message
         other ->
            original_request_id = message["id"]
            Logger.error("[Handler #{state.session_id}] Unexpected return from dispatch_request: #{inspect(other)}")
            if is_nil(original_request_id) do
              # Unexpected error during notification processing - log only
              Logger.error("[Handler #{state.session_id}] Unexpected error processing notification (method: #{message["method"]}): #{inspect other}")
              :ok
            else
              # Unexpected error during request processing - send error response
              error_response = %{jsonrpc: "2.0", id: original_request_id, error: %{code: -32603, message: "Internal server error processing message"}}
              send_sse_message_internal(state.plug_pid, error_response) # Send error over SSE
            end
      end
    else
      # Handle missing configuration
      Logger.error("[Handler #{state.session_id}] :implementation_module not configured for :mcp app.")
      error_response = %{jsonrpc: "2.0", id: message["id"], error: %{code: -32000, message: "Server configuration error: Missing implementation module"}}
      send_sse_message_internal(state.plug_pid, error_response)
    end
    # The {:noreply, state} needs to be outside the 'if implementation_module do' block
    {:noreply, state}
  end # End of handle_cast({:process_message, ...})

  @impl true # Correct placement for handle_cast({:send_message, ...})
  def handle_cast({:send_message, message}, state) do
    Logger.debug("[Handler #{state.session_id}] Received cast to send message: #{inspect message}")
    send_sse_message_internal(state.plug_pid, message)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_chunk, chunk}, state) do
     Logger.debug("[Handler #{state.session_id}] Received cast to send chunk: #{inspect chunk}")
     send_sse_chunk_internal(state.plug_pid, chunk)
     {:noreply, state} # State does not contain conn anymore
  end

  # Handle other messages if needed, e.g., termination signals (like client disconnect)
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
     if pid == state.plug_pid do
       Logger.info("[Handler #{state.session_id}] Monitored Plug process terminated. Reason: #{inspect reason}. Stopping handler.")
       {:stop, :normal, state}
     else
       Logger.warning("[Handler #{state.session_id}] Received DOWN signal for unexpected process #{inspect pid}. Reason: #{inspect reason}")
       {:noreply, state}
     end
  end

  @impl true # Moved @impl here for handle_info/2
  def handle_info(msg, state) do
    Logger.warning("[Handler #{state.session_id}] Received unknown info message: #{inspect msg}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[Handler #{state.session_id}] Terminating. Reason: #{inspect reason}")
    # Also tell the plug process to stop its loop if it's still alive
    # Use && for short-circuiting boolean logic
    if state.plug_pid && Process.alive?(state.plug_pid) do
      # Use send, not exit, to allow plug loop to cleanup gracefully
      send(state.plug_pid, {:stop})
    else
      Logger.warning("[Handler #{state.session_id}] Plug PID #{inspect state.plug_pid} not set or not alive during termination.")
    end
    # Unregister happens automatically via Registry monitoring if started under a supervisor
    # MCP.Server state cleanup (like ping loop) should happen implicitly when registry entry is gone.
    # Removed call to MCP.Server.stop(state.session_id) as it's undefined.
    :ok
  end

  # --- Private Helpers ---

  defp send_sse_message_internal(plug_pid, message) do
    if plug_pid do
      # Use encode! with pretty: false to ensure correct JSON formatting
      data = Jason.encode!(message, pretty: false)
      # Fix the string interpolation by using proper string concatenation
      chunk = "event: message\ndata: " <> data <> "\n\n"
      send_sse_chunk_internal(plug_pid, chunk)
    else
      Logger.error("[Handler Internal] Plug PID not set, cannot send message.")
      # Cannot send error back easily here as the connection pipe is broken
    end
  end

  defp send_sse_chunk_internal(plug_pid, chunk) do
    if plug_pid do
      # Check if plug process is alive before sending
      if Process.alive?(plug_pid) do
        send(plug_pid, {:send_chunk, chunk})
      else
        Logger.warning("[Handler Internal] Plug process #{inspect plug_pid} is not alive. Cannot send chunk: #{inspect chunk}")
      end
    else
      Logger.error("[Handler Internal] Plug PID not set, cannot send chunk.")
    end
  end
end # This is the correct end for defmodule SSE.ConnectionHandler
