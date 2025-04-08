import Config

# Configure MIME types for SSE
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}

# Configure the MCP protocol
config :mcp, MCP, [
  log_level: :info,
  supported_versions: ["2024-11-05"]
]
