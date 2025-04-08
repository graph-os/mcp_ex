# rel/config.exs
import Config

# Import the release configuration specific to the MIX_ENV
# environment. This will look for a file like config/prod.exs,
# config/dev.exs, etc.
import_config "../config/#{config_env()}.exs"

# Configure the release name and version.
release :mcp_ex do
  # Point to the main application for this release
  set application: :mcp # Assuming :mcp is the main OTP application
  # Set the version dynamically from the mix.exs file
  set version: Mix.Project.config()[:version]

  # No custom command needed, starting via Application module based on env var
  # command :stdio, :mcp, "MCP.StdioServer.start()"
end
