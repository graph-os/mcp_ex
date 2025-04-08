defmodule MCP.ServerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for Bandit server configuration in MCP
  """

  # Create a simple plug for testing
  defmodule TestPlug do
    @behaviour Plug
    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, "OK")
    end
  end

  setup do
    # Use a port in the test range that doesn't conflict with EndpointTest
    port = 49153

    # Start a Bandit server on a specified port
    {:ok, server_pid} = Bandit.start_link(
      plug: TestPlug,
      port: port
    )

    # Start Finch for HTTP requests
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, finch_pid} = Finch.start_link(name: ServerTestFinch)

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

    # Return the server and finch pids for use in tests along with the port
    {:ok, server_pid: server_pid, finch: finch_pid, port: port}
  end

  test "server should respond to HTTP requests", %{port: port} do
    # Make a request to the test server
    response =
      :get
      |> Finch.build("http://localhost:#{port}/")
      |> Finch.request!(ServerTestFinch)

    # Assert on the response
    assert response.status == 200
    assert response.body == "OK"
  end

  test "server should handle multiple simultaneous requests", %{port: port} do
    # Create multiple tasks to send requests concurrently
    tasks = for _ <- 1..5 do
      Task.async(fn ->
        :get
        |> Finch.build("http://localhost:#{port}/")
        |> Finch.request!(ServerTestFinch)
      end)
    end

    # Wait for all tasks to complete
    responses = Task.await_many(tasks)

    # Assert all responses were successful
    for response <- responses do
      assert response.status == 200
      assert response.body == "OK"
    end
  end

  test "server should handle different HTTP methods", %{port: port} do
    # Test POST method
    post_response =
      :post
      |> Finch.build("http://localhost:#{port}/")
      |> Finch.request!(ServerTestFinch)

    # Our simple test plug returns OK for all methods
    assert post_response.status == 200
    assert post_response.body == "OK"

    # Test PUT method
    put_response =
      :put
      |> Finch.build("http://localhost:#{port}/")
      |> Finch.request!(ServerTestFinch)

    assert put_response.status == 200
    assert put_response.body == "OK"
  end
end
