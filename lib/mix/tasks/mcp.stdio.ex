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

  @shortdoc "Provides a STDIO interface for the MCP server"

  def run(args) do
    # Parse options
    {opts, _, _} = OptionParser.parse(args, switches: [
      url: :string,
      direct: :boolean
    ])

    base_url = Keyword.get(opts, :url, "http://localhost:4004")
    direct = Keyword.get(opts, :direct, false)

    # Start the application to ensure dependencies are available
    Application.ensure_all_started(:mcp)
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:finch)

    # Set up logging to a file instead of stdout to avoid interference
    log_file = "/tmp/mcp_stdio_#{System.os_time(:second)}.log"
    File.write!(log_file, "Starting MCP STDIO adapter at #{DateTime.utc_now()}\n")

    # Configure logger to use the file
    Logger.configure(level: :debug)

    log = fn message ->
      File.write!(log_file, "#{message}\n", [:append])
    end

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

    # Start handling STDIO
    handle_stdio(fn message ->
      try do
        # Use MCP.Dispatcher.handle_request/3
        log.("Processing message: #{inspect(message)}")
        response_tuple = MCP.Dispatcher.handle_request(server_impl, session_id, message)
        log.("Got response tuple: #{inspect(response_tuple)}")

        case response_tuple do
          {:ok, result_map} -> result_map # handle_request returns the full response map
          {:error, {code, msg, data}} ->
            # Build the error response map directly
            %{
              jsonrpc: "2.0",
              id: message["id"],
              error: %{
                code: code,
                message: msg,
                data: data
              }
            }
        end
      rescue
        e ->
          log.("Error processing message: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
          # Build internal error response map directly
          %{
            jsonrpc: "2.0",
            id: message["id"],
            error: %{
              code: -32603, # Use @internal_error if defined
              message: "Internal error",
              data: %{"error" => inspect(e)}
            }
          }
      end
    end, log)
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
        handle_stdio(fn message ->
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

  # Handle STDIO I/O
  defp handle_stdio(message_handler, log) do
    log.("Starting STDIO handler")
    process_stdio(message_handler, log)
  end

  defp process_stdio(message_handler, log) do
    # Read a line from stdin
    case IO.gets("") do
      :eof ->
        log.("Received EOF, exiting")
        :ok

      {:error, reason} ->
        log.("Error reading from stdin: #{inspect(reason)}")
        :ok

      line ->
        line = String.trim(line)
        log.("Read line: #{inspect(line)}")

        if line != "" do
          try do
            # Parse the JSON-RPC message
            message = Jason.decode!(line)
            log.("Parsed JSON: #{inspect(message)}")

            # Process the message and get a response
            response = message_handler.(message)

            # Send the response back through stdout if not nil
            if response != nil do
              encoded_response = Jason.encode!(response)
              log.("Sending response: #{encoded_response}")
              IO.puts(encoded_response)
            else
              log.("No response to send (nil)")
            end
          rescue
            e ->
              log.("Error processing JSON: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
              # Handle parsing errors
              response = %{
                "jsonrpc" => "2.0",
                "id" => nil, # No way to know the ID if parsing failed
                "error" => %{
                  "code" => -32700,
                  "message" => "Parse error",
                  "data" => %{"error" => inspect(e)}
                }
              }

              encoded_response = Jason.encode!(response)
              log.("Sending error response: #{encoded_response}")
              IO.puts(encoded_response)
          end
        end

        # Continue processing
        process_stdio(message_handler, log)
    end
  end
end
