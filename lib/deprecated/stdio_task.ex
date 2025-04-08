defmodule Mix.Tasks.Mcp.Stdio do
  @moduledoc """
  Provides a STDIO interface for the MCP server.

  This task allows external tools like Windsurf to communicate with the MCP server
  using the STDIO protocol instead of HTTP/SSE.

  ## Usage

      mix mcp.stdio

  Options:
    * `--url` - URL of the running MCP server (default: http://localhost:4001)
    * `--direct` - Connect directly to the MCP GenServer instead of HTTP/SSE

  """
  use Mix.Task
  require Logger
  require MCP.StdioFraming # Add requirement for the framing module

  @shortdoc "Provides a STDIO interface for the MCP server"

  def run(args) do
    # --- Configure Logging First ---
    log_file = "/tmp/mcp_stdio_task_#{System.os_time(:second)}.log"
    File.write!(log_file, "Starting MCP STDIO Task at #{DateTime.utc_now()}\n")
    Logger.configure(level: :debug)
    Logger.add_backend({Logger.Backends.File, :stdio_task_log_file},
      path: log_file,
      level: :debug,
      format: "$time $metadata[$level] $message\n",
      metadata: [:level]
    )
    Logger.remove_backend(:console)
    # --- End Logging Config ---

    # Parse options
    {opts, _, _} = OptionParser.parse(args, switches: [
      url: :string,
      direct: :boolean
    ])

    base_url = Keyword.get(opts, :url, "http://localhost:4004")
    direct = Keyword.get(opts, :direct, false)

    # Log function using the file backend (requires Logger started)
    log = fn message ->
      # Manually write until Logger is guaranteed up?
      # Maybe better to just let Logger handle it once configured.
      File.write!(log_file, "#{message}\n", [:append])
    end

    # Start the application AFTER logger config
    log.("Ensuring applications started...")
    Application.ensure_all_started(:logger) # Ensure logger app itself is started
    Application.ensure_all_started(:mcp)
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:finch)
    log.("Applications started.")


    log.("MCP STDIO adapter started with options: #{inspect(opts)}")
    log.("Base URL: #{base_url}")

    if direct do
      log.("Running in direct mode")
      run_direct_mode(log)
    else
      log.("Running in HTTP mode with URL: #{base_url}")
      run_http_mode(base_url, log)
    end
  end

  # Direct mode: Connect directly to the MCP GenServer
  defp run_direct_mode(log) do
    # Generate a unique session ID for this STDIO connection
    session_id = UUID.uuid4()
    log.("Generated session ID: #{session_id}")

    # Register the session ID with the ConnectionRegistryServer, indicating stdio transport and initialized state
    # Explicitly pass the server name as the first argument
    initial_data = %{transport: :stdio, initialized: true}
    case SSE.ConnectionRegistryServer.register(SSE.ConnectionRegistryServer, session_id, initial_data) do
      :ok ->
        log.("Session #{session_id} registered successfully with data: #{inspect(initial_data)}")
      {:error, reason} ->
        log.("Failed to register session #{session_id}: #{inspect(reason)}")
        # Decide how to handle registration failure - maybe exit?
        # For now, just log and continue, but this might lead to issues later.
    end

    # Fetch the configured server implementation
    config = Application.get_env(:mcp, :endpoint, %{server: MCP.DefaultServer}) # Get config or use default
    server_impl = config.server
    log.("Using server implementation: #{inspect(server_impl)}")

    # Start the server process for this session
    # Note: We need a way to start the server process if it's not managed by Endpoint
    # This might involve calling server_impl.start_link or similar.
    # For now, assuming the server process can handle messages without explicit start
    # OR that the application starts a singleton server if needed.
    # server_impl.start(session_id) # Assuming a start function exists - adjust if needed

    # Define the message handler function
    message_handler = fn message ->
      # This internal message handler remains largely the same,
      # focusing on dispatching and formatting the JSON response/error.
      try do
        log.("Processing message: #{inspect(message)}")
        response_tuple = MCP.Dispatcher.handle_request(server_impl, session_id, message)
        log.("Got response tuple: #{inspect(response_tuple)}")

        # Determine what map to encode based on the dispatcher's response
        response_map_to_encode =
          case response_tuple do
            {:ok, map} ->
              log.("Dispatch successful, encoding result map: #{inspect map}")
              # Dispatcher now returns the full map for stdio
              map
            {:error, {code, msg, data}} ->
              log.("Dispatch returned error: #{code} - #{msg}")
              # Build the JSON-RPC error map
              %{
                "jsonrpc" => "2.0",
                "id" => message["id"], # Use ID from original request
                "error" => %{
                  "code" => code,
                  "message" => msg,
                  "data" => data
                }
              }
            _ ->
              log.("Unexpected response tuple format: #{inspect(response_tuple)}")
              nil # Results in no response being sent
          end
        response_map_to_encode
      rescue
        e ->
          log.("Error processing message: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
          %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "error" => %{
              "code" => -32603,
              "message" => "Internal error processing request",
              "data" => %{"error" => inspect(e)}
            }
          }
      end
    end

    # Start processing the stdio stream using the new framing logic and loop
    log.("Starting MCP.StdioFraming.process_stream...")
    MCP.StdioFraming.process_stream(:stdio, message_handler)
    log.("MCP.StdioFraming.process_stream finished.")
  end

  # HTTP mode: Connect to the MCP server via HTTP/SSE and handle JSON-RPC over HTTP
  defp run_http_mode(base_url, log) do
    # Create a unique name for this session's Finch instance
    finch_name = String.to_atom("MCP.Finch.#{System.os_time(:microsecond)}")
    log.("Starting Finch with name: #{finch_name}")

    # Start a dedicated Finch instance for this session
    {:ok, _} = Finch.start_link(name: finch_name)
    log.("Finch started successfully")

    # First connect to the SSE endpoint to get our session ID and endpoint
    sse_url = "#{base_url}/mcp/sse"
    log.("Connecting to SSE endpoint: #{sse_url}")

    case Finch.build(:get, sse_url) |> Finch.request(finch_name) do
      {:ok, %{status: 200, body: body}} ->
        log.("Connected to SSE endpoint successfully")

        # Extract the session_id and message_endpoint from the SSE response
        # The response is in SSE format like: event: message\ndata: {"session_id":"...","message_endpoint":"..."}
        {session_id, message_endpoint} = parse_sse_response(body, log)
        log.("Parsed session ID: #{session_id}")
        log.("Parsed message endpoint: #{message_endpoint}")

        # The full RPC endpoint URL
        rpc_url = "#{base_url}#{message_endpoint}"
        log.("RPC endpoint: #{rpc_url}")

        # Start handling STDIO with the obtained session ID and endpoint
        handle_stdio_framed(fn message ->
          try do
            # Add session_id to the message if needed
            message_with_session =
              if Map.has_key?(message, "params") && is_map(message["params"]) do
                put_in(message, ["params", "session_id"], session_id)
              else
                message
              end

            # Send the message to the MCP server via HTTP
            encoded_message = Jason.encode!(message_with_session)
            log.("Sending HTTP request to #{rpc_url}: #{encoded_message}")

            case Finch.build(:post, rpc_url, [{"content-type", "application/json"}], encoded_message)
                 |> Finch.request(finch_name) do
              {:ok, %{status: 200, body: response_body}} ->
                log.("Got HTTP response: #{response_body}")
                Jason.decode!(response_body)
              {:ok, response} ->
                log.("Got non-200 HTTP response: #{inspect(response)}")
                %{
                  "jsonrpc" => "2.0",
                  "id" => message["id"],
                  "error" => %{
                    "code" => -32603,
                    "message" => "HTTP error",
                    "data" => %{"status" => response.status, "body" => response.body}
                  }
                }
              {:error, error} ->
                log.("HTTP request error: #{inspect(error)}")
                %{
                  "jsonrpc" => "2.0",
                  "id" => message["id"],
                  "error" => %{
                    "code" => -32603,
                    "message" => "Connection error",
                    "data" => %{"error" => inspect(error)}
                  }
                }
            end
          rescue
            e ->
              log.("Error in HTTP request: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
              %{
                "jsonrpc" => "2.0",
                "id" => message["id"],
                "error" => %{
                  "code" => -32603,
                  "message" => "Internal error",
                  "data" => %{"error" => inspect(e)}
                }
              }
          end
        end, log)

      {:ok, response} ->
        log.("Failed to connect to SSE endpoint: #{inspect(response)}")
        IO.puts(Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{
            "code" => -32603,
            "message" => "Failed to connect to SSE endpoint",
            "data" => %{"status" => response.status, "body" => response.body}
          }
        }))

      {:error, error} ->
        log.("Error connecting to SSE endpoint: #{inspect(error)}")
        IO.puts(Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{
            "code" => -32603,
            "message" => "Failed to connect to SSE endpoint",
            "data" => %{"error" => inspect(error)}
          }
        }))
    end
  end

  # Parse the SSE response to extract session_id and message_endpoint
  defp parse_sse_response(body, log) do
    log.("Parsing SSE response: #{inspect(body)}")

    # Find the data line in the SSE response
    case Regex.run(~r/data: (\{.*\})/, body) do
      [_, json_str] ->
        log.("Found JSON data: #{json_str}")

        # Parse the JSON data
        case Jason.decode(json_str) do
          {:ok, %{"session_id" => session_id, "message_endpoint" => message_endpoint}} ->
            log.("Parsed session ID: #{session_id}")
            log.("Parsed message endpoint: #{message_endpoint}")
            {session_id, message_endpoint}

          {:ok, data} ->
            log.("Unexpected JSON format: #{inspect(data)}")
            {"", "/mcp/jsonrpc"} # Fallback to default

          {:error, error} ->
            log.("Error parsing JSON: #{inspect(error)}")
            {"", "/mcp/jsonrpc"} # Fallback to default
        end

      nil ->
        log.("Could not find data pattern in SSE response")
        {"", "/mcp/jsonrpc"} # Fallback to default
    end
  end

  # --- New Framed STDIO Handling ---

  # Handle STDIO I/O with length-prefix framing
  defp handle_stdio_framed(message_handler, log) do
    log.("Starting framed STDIO handler")
    # Initial call to the recursive processing function
    process_stdio_framed(message_handler, log)
  end

  # Recursive function to read framed messages, process, and write framed responses
  defp process_stdio_framed(message_handler, log) do
    case MCP.StdioFraming.read_message(:stdio) do
      {:ok, binary_payload} ->
        log.("Framed message read successfully (#{byte_size(binary_payload)} bytes)")
        try do
          message = Jason.decode!(binary_payload)
          log.("Parsed JSON: #{inspect(message)}")

          # Process the message using the provided handler
          response_map = message_handler.(message)

          # Send the response map back if not nil
          if response_map != nil do
            log.("Encoding response map: #{inspect(response_map)}")
            encoded_response = Jason.encode!(response_map)
            log.("Sending framed response (#{byte_size(encoded_response)} bytes)")
            case MCP.StdioFraming.write_message(:stdio, encoded_response) do
              :ok -> log.("Framed response sent successfully.")
              {:error, reason} -> log.("Error sending framed response: #{inspect(reason)}")
            end
          else
            log.("No response map to send (nil).")
          end
        rescue
          e ->
            log.("Error decoding JSON or processing message: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
            # Handle JSON parsing errors or other exceptions
            # Respond with a JSON-RPC error message, framed
            error_response = %{
              "jsonrpc" => "2.0",
              "id" => nil, # ID might not be known if JSON parsing failed
              "error" => %{
                "code" => -32700, # Parse error
                "message" => "Error processing request: #{inspect(e)}",
                "data" => nil
              }
            }
            encoded_error = Jason.encode!(error_response)
            log.("Sending framed error response due to exception: #{encoded_error}")
            MCP.StdioFraming.write_message(:stdio, encoded_error)
            # Decide whether to continue or exit on error
        end
        # Continue processing the next message
        process_stdio_framed(message_handler, log)

      {:error, :eof} ->
        log.("Received EOF, exiting framed handler")
        :ok # End of input

      {:error, reason} ->
        log.("Error reading framed message: #{inspect(reason)}")
        :ok # Potentially exit or handle specific errors
    end
  end

  # Deprecated/Removed original handle_stdio and process_stdio
  # defp handle_stdio(message_handler, log) do ... end
  # defp process_stdio(message_handler, log) do ... end
end
