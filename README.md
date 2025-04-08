# MCP (Model Context Protocol) Elixir Implementation

Model Context Protocol (MCP) implementation in Elixir.

This library provides a complete implementation of the Model Context Protocol (MCP), enabling AI assistants to interact with backend systems through a standardized protocol.

## Features

- Full implementation of the Model Context Protocol (MCP) v"2024-11-05"
- Server-sent events (SSE) for real-time communication
- JSON-RPC for request/response communication
- Type validation with JSON Schema
- Tool registration and execution
- Resource and prompt management
- Client implementation using Elixir Agent pattern
- Customizable server implementations
- Default server with basic tools

## Installation

Add `mcp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mcp, "~> 0.1.0"}
  ]
end
```

## Usage

### Starting an MCP Server

The simplest way to start an MCP server (using the default implementation) is to use the `mix mcp.start` command:

```bash
# Start and join the MCP server (requires tmux)
mix mcp.start

# Start the server without joining the tmux session
mix mcp.start --no-join
```

This command will start the MCP server in a tmux session and automatically join the session if possible. To detach from the session, press Ctrl+B then D.

When running in non-interactive terminals (like in VS Code's integrated terminal), the command will automatically detect this and provide instructions for joining the session manually.

For more fine-grained control, you can use the `mcp.server` mix task:

```bash
# Start the server
mix mcp.server start

# Check server status
mix mcp.server status

# Join the server session
mix mcp.server join

# Stop the server
mix mcp.server stop
```

For programmatic usage, you can use the `MCP.ServerEndpoint` plug:

```elixir
# In your application's supervision tree
children = [
  {MCP.ServerEndpoint,
    server: MCP.DefaultServer,
    port: 4000,
    mode: :debug
  }
]

Supervisor.start_link(children, strategy: :one_for_one)
```

This will start an MCP server that uses the `MCP.DefaultServer` implementation, listening on port 4000, with debug mode enabled.

### Creating a Custom MCP Server

You can create your own MCP server implementation by implementing the `MCP.Server` behaviour:

```elixir
defmodule MyApp.MCPServer do
  use MCP.Server
  require Logger

  @impl true
  def handle_initialize(session_id, request_id, params) do
    # Custom initialization logic
    {:ok, %{
      protocolVersion: MCP.Types.latest_protocol_version(),
      serverInfo: %{
        name: "My Custom MCP Server",
        version: "1.0.0"
      },
      capabilities: %{
        tools: %{
          listChanged: true
        }
      }
    }}
  end

  @impl true
  def handle_list_tools(session_id, request_id, _params) do
    # Return custom tools
    {:ok, %{
      tools: [
        %{
          name: "my_custom_tool",
          description: "A custom tool",
          inputSchema: %{
            type: "object",
            properties: %{
              input: %{
                type: "string"
              }
            }
          },
          outputSchema: %{
            type: "object",
            properties: %{
              output: %{
                type: "string"
              }
            }
          }
        }
      ]
    }}
  end

  @impl true
  def handle_tool_call(session_id, request_id, "my_custom_tool", arguments) do
    # Custom tool implementation
    input = arguments["input"] || ""
    {:ok, %{
      content: [
        %{
          type: "text",
          text: "Custom tool response: #{input}"
        }
      ]
    }}
  end
end
```

### Using the MCP Client

The `MCP.Client` module provides an Elixir client for connecting to MCP servers:

```elixir
# Start a client
{:ok, client} = MCP.Client.start_link(url: "http://localhost:4000/mcp/sse")

# Initialize the connection
{:ok, result} = MCP.Client.initialize(client)

# List available tools
{:ok, tools} = MCP.Client.list_tools(client)

# Call a tool
{:ok, result} = MCP.Client.call_tool(client, "echo", %{text: "Hello, World!"})

# Register an event handler
MCP.Client.register_event_handler(client, "notification", fn event, _client ->
  IO.puts("Received notification: #{inspect(event)}")
end)

# Stop the client when done
MCP.Client.stop(client)
```

### Testing with the MCP Test Server

For testing purposes, you can use the `MCP.TestServer` module which provides a simple in-memory server:

```elixir
# Start the test server
MCP.TestServer.start()

# List available tools
{:ok, tools} = MCP.TestServer.list_tools()

# Call a tool
{:ok, result} = MCP.TestServer.call_tool("echo", %{text: "Hello, World!"})

# Stop the test server
MCP.TestServer.stop()
```

## Architecture

The MCP Elixir implementation consists of the following components:

- **MCP.Server**: The behavior and base implementation for MCP servers
- **MCP.DefaultServer**: A default implementation of the MCP server behavior
- **MCP.Client**: An Elixir client for connecting to MCP servers
- **MCP.ServerEndpoint**: A reusable MCP server endpoint
- **MCP.Types**: Type definitions and validation for MCP

### Protocol Flow

1. Client connects to the SSE endpoint (`/mcp/sse`)
2. Server sends the message endpoint to the client (`/mcp/message`)
3. Client sends an initialize request to the message endpoint
4. Server responds with protocol version and capabilities
5. Client can list and call tools, fetch resources, etc.

## Configuration

### Server Configuration

The MCP server can be configured with the following options:

```elixir
config :mcp, MCP,
  log_level: :info,
  supported_versions: ["2024-11-05"]
```

### Endpoint Configuration

The `MCP.ServerEndpoint` can be configured with the following options:

- `:server` - The MCP server module to use (default: `MCP.DefaultServer`)
- `:port` - The port to listen on (default: 4000)
- `:mode` - The mode to use (`:sse`, `:debug`, or `:inspect`) (default: `:sse`)
- `:host` - The host to bind to (default: "0.0.0.0")
- `:path_prefix` - The URL path prefix for MCP endpoints (default: "/mcp")

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
