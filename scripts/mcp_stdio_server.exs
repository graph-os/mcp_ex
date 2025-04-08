# scripts/mcp_stdio_server.exs

# Configure Logger FIRST to capture app start messages
log_file = "/tmp/mcp_stdio_server_#{System.os_time(:second)}.log"
File.write!(log_file, "Starting MCP STDIO Server Script at #{DateTime.utc_now()}\n")
Logger.configure(level: :debug)
Logger.add_backend({Logger.Backends.File, :stdio_log_file},
  path: log_file,
  level: :debug, # Or desired level
  format: "$time $metadata[$level] $message\n",
  metadata: [:level]
)
# Remove console backend to ensure nothing goes to stdio
Logger.remove_backend(:console)

# Use Mix to ensure the full app environment is loaded
Mix.Task.run("app.start")

# Run the stdio server logic
case MCP.StdioServer.start() do
  :ok ->
    exit(:normal)
  {:error, reason} ->
    # Use IO.inspect to stderr for critical exit errors
    IO.inspect({"StdioServer failed", reason}, label: "MCP STDIO Server Script Error", to: :stderr)
    exit({:server_error, reason})
end
