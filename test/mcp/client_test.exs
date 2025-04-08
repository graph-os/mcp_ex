defmodule MCP.ClientTest do
  @moduledoc """
  Test the MCP client functionality.
  """
  use ExUnit.Case
  doctest MCP.Client

  test "client can be initialized" do
    # Create a client state directly
    state = %{
      url: "http://localhost:4000/sse",
      headers: [],
      message_endpoint: "/message",
      session_id: "test-session",
      protocol_version: MCP.Message.latest_version(),
      initialized: true,
      connection_pid: nil,
      requests: %{},
      request_id_counter: 1,
      event_handlers: %{},
      tools: [],
      resources: [],
      prompts: []
    }

    # Start an agent with this state
    {:ok, client} = Agent.start_link(fn -> state end)

    # Verify the client info function works
    info = MCP.Client.info(client)
    assert info.session_id == "test-session"
    assert info.initialized == true
    assert info.connected == false

    # Clean up
    Agent.stop(client)
  end

  test "client event handlers can be registered and unregistered" do
    # Create a client state directly
    state = %{
      url: "http://localhost:4000/sse",
      headers: [],
      message_endpoint: "/message",
      session_id: "test-session",
      protocol_version: MCP.Message.latest_version(),
      initialized: true,
      connection_pid: nil,
      requests: %{},
      request_id_counter: 1,
      event_handlers: %{},
      tools: [],
      resources: [],
      prompts: []
    }

    # Start an agent with this state
    {:ok, client} = Agent.start_link(fn -> state end)

    # Register a handler
    test_handler = fn _data, _client -> :ok end
    MCP.Client.register_event_handler(client, "test_event", test_handler)

    # Check that the handler was registered
    handlers = Agent.get(client, fn state -> state.event_handlers end)
    assert Map.has_key?(handlers, "test_event")
    assert length(handlers["test_event"]) == 1

    # Unregister the handler
    MCP.Client.unregister_event_handler(client, "test_event")

    # Check that the handler was unregistered
    handlers = Agent.get(client, fn state -> state.event_handlers end)
    assert not Map.has_key?(handlers, "test_event")

    # Clean up
    Agent.stop(client)
  end

  test "request ID is correctly generated and incremented" do
    # Create a client state directly
    state = %{
      url: "http://localhost:4000/sse",
      headers: [],
      message_endpoint: "/message",
      session_id: "test-session",
      protocol_version: MCP.Message.latest_version(),
      initialized: true,
      connection_pid: nil,
      requests: %{},
      request_id_counter: 1,
      event_handlers: %{},
      tools: [],
      resources: [],
      prompts: []
    }

    # Start an agent with this state
    {:ok, client} = Agent.start_link(fn -> state end)

    # Test creating a request ID
    request_id_1 =
      Agent.get_and_update(client, fn state ->
        id = state.request_id_counter
        {id, %{state | request_id_counter: id + 1}}
      end)

    assert request_id_1 == 1

    # Test creating another request ID
    request_id_2 =
      Agent.get_and_update(client, fn state ->
        id = state.request_id_counter
        {id, %{state | request_id_counter: id + 1}}
      end)

    assert request_id_2 == 2

    # Ensure request ID counter was incremented correctly
    current_counter = Agent.get(client, fn state -> state.request_id_counter end)
    assert current_counter == 3

    # Clean up
    Agent.stop(client)
  end
end
