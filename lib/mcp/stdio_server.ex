defmodule MCP.StdioServer do
  @moduledoc """
  Handles the server-side logic for a direct MCP stdio connection.
  Assumes the necessary applications (:logger, :mcp, :jason, :uuid) have been started by the main Application.
  """
  require Logger
  require MCP.StdioFraming
  alias SSE.ConnectionRegistryServer

  def start() do
    # Logger should be configured by the time this runs if Application starts it
    # Configure file logging just in case, but don't ensure_all_started(:logger) here
    log_file = "/tmp/mcp_stdio_server_#{System.os_time(:second)}.log"
    File.write!(log_file, "Starting MCP STDIO Server Process at #{DateTime.utc_now()}\n")
    Logger.add_backend({Logger.Backends.File, :stdio_srv_log_file},
      path: log_file,
      level: :debug,
      format: "$time $metadata[$level] $message\n",
      metadata: [:level]
    )
    # Do NOT remove console here, the main app might still use it
    # Logger.remove_backend(:console)

    Logger.info("MCP STDIO Server start() function executing.")

    # --- REMOVE Ensure dependent apps are started ---
    # try do
    #   :ok = Application.ensure_all_started(:mcp)
    #   :ok = Application.ensure_all_started(:jason)
    #   :ok = Application.ensure_all_started(:uuid)
    #   Logger.info("Dependent applications checked.")
    # rescue
    #    e -> # Match the exception
    #      stack = Exception.format_stacktrace(__STACKTRACE__)
    #      Logger.error("Dependent application start failed in StdioServer: #{inspect(e)}\n#{stack}")
    #      exit({:app_start_failed_in_stdio, {e, stack}})
    # end

    session_id = UUID.uuid4()
    Logger.info("Generated session ID: #{session_id}")

    initial_data = %{transport: :stdio, initialized: false}
    Logger.info("Attempting to register session #{session_id}...")
    case ConnectionRegistryServer.register(SSE.ConnectionRegistryServer, session_id, initial_data) do
      :ok ->
        Logger.info("Session #{session_id} registered successfully.")
      {:error, reason} ->
        Logger.error("Failed to register session #{session_id}: #{inspect(reason)}")
        exit({:registration_failed, reason})
    end

    config = Application.get_env(:mcp, :endpoint, %{server: MCP.DefaultServer})
    server_impl = config.server
    Logger.info("Using server implementation: #{inspect(server_impl)}")

    message_handler = fn message ->
      try do
        Logger.debug("Processing message: #{inspect(message)}")
        response_tuple = MCP.Dispatcher.handle_request(server_impl, session_id, message)
        Logger.debug("Dispatcher response tuple: #{inspect(response_tuple)}")
        response_map_to_encode =
          case response_tuple do
            {:ok, map} ->
              Logger.debug("Dispatch successful, encoding result map: #{inspect map}")
              map
            {:error, {code, msg, data}} ->
              Logger.error("Dispatch returned error: #{code} - #{msg}")
              %{
                "jsonrpc" => "2.0",
                "id" => message["id"],
                "error" => %{
                  "code" => code,
                  "message" => msg,
                  "data" => data
                }
              }
            _ ->
              Logger.error("Unexpected dispatcher response tuple format: #{inspect(response_tuple)}")
              nil
          end
        response_map_to_encode
      rescue
        e ->
          stack = Exception.format_stacktrace(__STACKTRACE__)
          Logger.error("Error in message_handler: #{inspect(e)}\n#{stack}")
          %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "error" => %{
              "code" => -32603,
              "message" => "Internal error processing request: #{inspect(e)}",
              "data" => %{"stacktrace" => stack}
            }
          }
      end
    end

    Logger.info("Starting MCP.StdioFraming.process_stream...")
    result = MCP.StdioFraming.process_stream(:stdio, message_handler)
    Logger.info("MCP.StdioFraming.process_stream finished with result: #{inspect(result)}")

    Logger.info("Unregistering session #{session_id}")
    ConnectionRegistryServer.unregister(session_id)
    Logger.info("Exiting MCP.StdioServer.start() with result: #{inspect(result)}")

    result
  end
end
