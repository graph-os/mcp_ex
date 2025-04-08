defmodule Mix.Tasks.Mcp.TestClient do
  @moduledoc """
  Starts an MCP server, runs the TypeScript MCP client test script against it,
  and then stops the server.

  This task performs the following steps:
  1. Checks for `node` and `npx` executables.
  2. Calculates necessary paths.
  3. Starts a temporary supervisor and the MCP.Endpoint server as a child.
  4. Waits briefly for the server to start.
  5. Runs `npm install` in the `mcp-sdk/typescript-client-test` directory.
  6. Runs the `test_connection.ts` script using `npx tsx` against the started server.
  7. Streams the output and exits with the script's status code.
  8. Ensures the server supervisor is stopped in an `after` block.
  """
  use Mix.Task
  require Logger

  @shortdoc "Starts server and runs the TypeScript MCP client test script"

  @switches [port: :integer]
  @aliases [p: :port]

  @impl Mix.Task
  def run(args) do
    # Parse command-line options
    {opts, _parsed_args, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    port = Keyword.get(opts, :port, 4004)

    # Ensure Mix project is loaded
    Mix.Project.get!()

    # 1. Check dependencies (Node.js/npx)
    check_node_deps()

    # 2. Calculate Paths
    {client_test_dir, ts_script_full_path} = calculate_paths()
    verify_script_exists(client_test_dir, ts_script_full_path)

    # Ensure the main MCP application (including Registry) is started
    {:ok, _} = Application.ensure_all_started(:mcp)

    # 3. Start Server in a Supervisor
    sup_name = Module.concat(__MODULE__, "Supervisor")
    endpoint_opts = [port: port, mode: :debug] # Use debug mode for /rpc
    children = [{MCP.Endpoint, endpoint_opts}]

    # Start supervisor linked to current process
    {:ok, sup_pid} = Supervisor.start_link(children, strategy: :one_for_one, name: sup_name)
    Logger.info("Started test server supervisor: #{inspect sup_pid}")

    # Give server a moment to start
    Process.sleep(200)

    exit_status = 0
    try do
      # 4. Run npm install
      run_npm_install(client_test_dir)

      # 5. Run the TypeScript test script
      exit_status = run_ts_test(client_test_dir, ts_script_full_path, port)
    after
      # 6. Ensure server is stopped
      Logger.info("Stopping test server supervisor: #{inspect sup_pid}")
      Supervisor.stop(sup_pid, :shutdown)
      Logger.info("Test server supervisor stopped.")
    end

    # 7. Exit with appropriate status code
    if exit_status != 0 do
      System.at_exit(fn _ -> exit({:shutdown, exit_status}) end)
    end
  end

  # --- Helper Functions ---

  defp check_node_deps do
    unless System.find_executable("node") && System.find_executable("npx") do
      Mix.raise("Node.js and npx are required to run the TypeScript client test.")
    end
  end

  defp calculate_paths do
    app_path = Mix.Project.app_path()
    lib_dir = Path.dirname(app_path)
    env_dir = Path.dirname(lib_dir)
    build_dir = Path.dirname(env_dir)
    root_dir = Path.dirname(build_dir)
    client_test_dir = Path.join(root_dir, "typescript-client-test")
    ts_test_script = "test_connection.ts"
    ts_script_full_path = Path.join(client_test_dir, ts_test_script)
    {client_test_dir, ts_script_full_path}
  end

  defp verify_script_exists(client_test_dir, ts_script_full_path) do
    # List directory contents for debugging
    # Mix.shell().info("Listing contents of: #{client_test_dir}")
    # case File.ls(client_test_dir) do
    #   {:ok, files} -> Mix.shell().info("Files: #{inspect(files)}")
    #   {:error, reason} -> Mix.shell().error("Error listing directory: #{inspect(reason)}")
    # end
    unless File.exists?(ts_script_full_path) do
      Mix.raise("TypeScript test script not found at #{ts_script_full_path}")
    end
  end

  defp run_npm_install(client_test_dir) do
    Mix.shell().info("Running npm install in #{client_test_dir}...")
    opts_install = [stderr_to_stdout: true, cd: client_test_dir]
    case System.cmd("npm", ["install"], opts_install) do
      {_output, 0} -> Mix.shell().info("npm install completed.")
      {output, status} -> Mix.raise("npm install failed with status #{status}. Output:\n#{output}")
    end
  end

  defp run_ts_test(client_test_dir, ts_script_full_path, port) do
    # Use full path for script
    ts_script_arg = Path.relative_to(ts_script_full_path, client_test_dir)

    Mix.shell().info("Running TypeScript client test: #{ts_script_arg} against port #{port}...")
    env = %{"MCP_SERVER_PORT" => Integer.to_string(port)}
    opts_run = [stderr_to_stdout: true, cd: client_test_dir, into: IO.stream(:stdio, :line), env: env]

    case System.cmd("npx", ["tsx", ts_script_arg], opts_run) do
      {_output, 0} ->
        Mix.shell().info("TypeScript client test completed successfully.")
        0 # Return exit status 0
      {_output, status} ->
        Mix.shell().error("TypeScript client test failed with status #{status}.")
        status # Return non-zero exit status
    end
  end
end
