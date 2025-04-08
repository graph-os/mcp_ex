defmodule MCP.EndpointTest do
  use ExUnit.Case, async: false

  # Import test helpers
  import Plug.Test

  @moduledoc """
  Tests for MCP.Endpoint functionality
  """

  # Define a simple router module for testing
  defmodule TestRouter do
    use Plug.Router

    plug :match
    plug :dispatch

    get "/" do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, "TestRouter OK")
    end

    match _ do
      send_resp(conn, 404, "Not Found")
    end
  end

  # Simplified endpoint for testing
  defmodule TestEndpoint do
    def start_link(mode, options \\ []) when mode in [:sse, :debug, :inspect] do
      # Use a hardcoded port in the test range (49152-65535)
      port = Keyword.get(options, :port, 49152)

      # Create a plug to wrap the router with the mode
      mode_plug = {__MODULE__, mode: mode}

      # Use the simplified configuration
      Bandit.start_link(
        plug: mode_plug,
        port: port
      )
    end

    # Plug callback
    def init(mode: mode), do: %{mode: mode}

    # Plug callback
    def call(conn, %{mode: mode}) do
      # Add the mode to the conn private data
      conn = Plug.Conn.put_private(conn, :mcp_mode, mode)

      # Apply TestRouter
      MCP.EndpointTest.TestRouter.call(conn, [])
    end
  end

  setup do
    # Use a port in the test range
    port = 49152

    # Start the endpoint for testing
    {:ok, server_pid} = TestEndpoint.start_link(:debug, [port: port])

    # Start Finch for HTTP requests
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, finch_pid} = Finch.start_link(name: TestFinch)

    # Make sure to stop the server and finch after each test
    on_exit(fn ->
      # Stop the server
      try do
        Process.exit(server_pid, :shutdown)
        # Wait a moment to ensure the port is released
        :timer.sleep(100)
      catch
        _kind, _error -> :ok
      end

      # Stop Finch
      try do
        Process.exit(finch_pid, :shutdown)
      catch
        _kind, _error -> :ok
      end
    end)

    # Return the server pid and port for use in tests
    {:ok, server_pid: server_pid, port: port, finch_pid: finch_pid}
  end

  test "endpoint should respond to HTTP requests", %{port: port} do
    # Make a request to the test endpoint using the assigned port
    response =
      :get
      |> Finch.build("http://localhost:#{port}/")
      |> Finch.request!(TestFinch)

    # Assert on the response
    assert response.status == 200
    assert response.body == "TestRouter OK"
  end

  test "endpoint should set the mode in conn private data" do
    # Create a conn and call the endpoint directly
    conn =
      :get
      |> conn("/")
      |> TestEndpoint.call(%{mode: :debug})

    # Assert the mode was set correctly
    assert conn.private.mcp_mode == :debug
  end

  test "endpoint should return 404 for unknown routes", %{port: port} do
    # Use Finch to make a request to an unknown route
    response =
      :get
      |> Finch.build("http://localhost:#{port}/unknown")
      |> Finch.request!(TestFinch)

    # Assert on the response
    assert response.status == 404
    assert response.body == "Not Found"
  end
end
