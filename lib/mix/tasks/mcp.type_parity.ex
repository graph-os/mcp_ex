defmodule Mix.Tasks.Mcp.TypeParity do
  @moduledoc """
  Mix task to run type parity tests for MCP, ensuring Elixir and TypeScript types are in sync.

  This task coordinates running both Elixir and TypeScript tests to ensure that type definitions
  in both languages remain compatible.

  ## Usage

  ```
  mix mcp.type_parity [--debug] [--skip-typescript]
  ```

  Options:
  - `--debug`: Run tests with debug logging enabled
  - `--skip-typescript`: Only run Elixir tests, skip TypeScript tests (useful during development)
  """

  use Mix.Task

  @shortdoc "Run MCP type parity tests between Elixir and TypeScript"
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [debug: :boolean, skip_typescript: :boolean])

    # Set log level for tests
    log_level = if opts[:debug], do: :debug, else: :warn
    Application.put_env(:mcp, MCP, [log_level: log_level])

    # Check test environment
    Mix.shell().info("Running MCP type parity tests with log level: #{log_level}")

    # Check protocol versions are in sync
    check_protocol_versions()

    # First run Elixir tests
    Mix.shell().info("Running Elixir type tests...")
    case Mix.Task.run("test", ["test/mcp/types_test.exs"]) do
      :ok -> Mix.shell().info("Elixir type tests passed!")
      _error -> Mix.raise("Elixir type tests failed! Fix Elixir tests before continuing.")
    end

    # Skip TypeScript tests if requested
    if opts[:skip_typescript] do
      Mix.shell().info("\nSkipping TypeScript tests as requested.")
    else
      # Then run TypeScript tests
      Mix.shell().info("\nRunning TypeScript type tests...")

      # Check if npm is installed
      case System.cmd("which", ["npm"], stderr_to_stdout: true) do
        {_, 0} ->
          # npm is available, run the tests
          case System.cmd("npm", ["test", "--", "type-parity"], cd: Path.join(File.cwd!(), "assets")) do
            {output, 0} ->
              Mix.shell().info(output)
              Mix.shell().info("TypeScript type tests passed!")
            {output, _} ->
              Mix.shell().error(output)
              Mix.raise("TypeScript type tests failed! Fix TypeScript tests before continuing.")
          end
        _ ->
          Mix.shell().error("npm not found. Make sure npm is installed and in your PATH.")
          Mix.raise("Cannot run TypeScript tests without npm.")
      end
    end

    Mix.shell().info("\nAll type parity tests completed successfully.")
  end

  # Ensure protocol versions are in sync between Elixir and TypeScript
  defp check_protocol_versions do
    Mix.shell().info("Checking protocol version parity...")

    elixir_version = MCP.Message.latest_version()

    # Read TS file to extract version
    ts_file = Path.join([File.cwd!(), "assets", "types", "mcp-types.ts"])

    if File.exists?(ts_file) do
      ts_content = File.read!(ts_file)

      # Extract the version from the TS file using regex
      ts_version_regex = ~r/LATEST_PROTOCOL_VERSION\s*=\s*"([^"]+)"/
      ts_version = case Regex.run(ts_version_regex, ts_content) do
        [_, version] -> version
        _ ->
          Mix.shell().error("Could not find LATEST_PROTOCOL_VERSION in TypeScript file")
          "not found"
      end

      if elixir_version == ts_version do
        Mix.shell().info("Protocol versions match: #{elixir_version}")
      else
        Mix.shell().error("Protocol version mismatch!")
        Mix.shell().error("Elixir version: #{elixir_version}")
        Mix.shell().error("TypeScript version: #{ts_version}")
        Mix.raise("Protocol versions must match")
      end
    else
      Mix.shell().error("TypeScript type file not found at: #{ts_file}")
      Mix.raise("Cannot check protocol versions without TypeScript type file")
    end
  end
end
