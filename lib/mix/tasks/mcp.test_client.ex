defmodule Mix.Tasks.Mcp.TestClient do
  @moduledoc """
  Starts an MCP server (either default or task-specific), runs the corresponding
  TypeScript MCP client test script against it, and then stops the server.

  Accepts a `--target` argument ('default' or 'task') to select the configuration.

  This task performs the following steps:
  1. Checks for `node` and `npx` executables.
  2. Parses arguments (`--port`, `--target`).
  3. Calculates necessary paths based on the target.
  4. Starts a temporary supervisor and the MCP.Endpoint server as a child with the correct port.
  5. Waits briefly for the server to start.
  6. Runs `npm install` in the `typescript-client-test` directory.
  7. Runs the appropriate test script (`test_connection.ts` or `test_task_connection.ts`)
     using `npx tsx` against the started server, setting the correct environment variable
     (`MCP_SERVER_PORT` or `MCP_TASK_SERVER_PORT`).
  8. Streams the output and exits with the script's status code.
  9. Ensures the server supervisor is stopped in an `after` block.
  """
  use Mix.Task
  require Logger

  @shortdoc "Starts server and runs a specific TypeScript MCP client test script"

  @switches [port: :integer, target: :string]
  @aliases [p: :port, t: :target]

  @impl Mix.Task
  def run(args) do
    # 1. Parse command-line options
    {opts, _parsed_args, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    # Determine target ('default' or 'task')
    target = Keyword.get(opts, :target, "default") # Default to "default"
    unless target in ["default", "task"] do
      Mix.raise("Invalid --target value: '#{target}'. Must be 'default' or 'task'.")
    end

    # Determine port based on target, overridden by --port
    default_port = if target == "task", do: 4001, else: 4000
    port = Keyword.get(opts, :port, default_port)

    # Determine script name and env var based on target
    {ts_test_script, port_env_var} =
      case target do
        "task" -> {"test_task_connection.ts", "MCP_TASK_SERVER_PORT"}
        _      -> {"test_connection.ts", "MCP_SERVER_PORT"} # Default case
      end

    Logger.info("Selected target: #{target}, script: #{ts_test_script}, port: #{port}, env_var: #{port_env_var}")

    # 2. Ensure Mix project is loaded
    Mix.Project.get!()

    # 3. Check dependencies (Node.js/npx)
    check_node_deps()

    # 4. Calculate Paths based on the selected script
    {client_test_dir, ts_script_full_path} = calculate_paths(ts_test_script)
    verify_script_exists(client_test_dir, ts_script_full_path)

    # 5. Ensure the main MCP application (including Registry) is started
    {:ok, _} = Application.ensure_all_started(:mcp)

    # 6. Start Server in a Supervisor
    sup_name = Module.concat(__MODULE__, "Supervisor")
    # Determine path prefix based on target
    path_prefix = if target == "task", do: "/task", else: ""
    # Use the determined port and path prefix for the endpoint
    endpoint_opts = [port: port, mode: :debug, path_prefix: path_prefix]
    children = [{MCP.Endpoint, endpoint_opts}]

    # Start supervisor linked to current process
    {:ok, sup_pid} = Supervisor.start_link(children, strategy: :one_for_one, name: sup_name)
    Logger.info("Started test server supervisor: #{inspect sup_pid} for target '#{target}' on port #{port} with prefix '#{path_prefix}'")

    # Give server a moment to start
    Process.sleep(500)

    exit_status = 0
    try do
      # 7. Run npm install
      run_npm_install(client_test_dir)

      # 8. Run the correct TypeScript test script with the correct env var
      exit_status = run_ts_test(client_test_dir, ts_script_full_path, port, port_env_var)
    after
      # 9. Ensure server is stopped
      Logger.info("Stopping test server supervisor: #{inspect sup_pid}")
      Supervisor.stop(sup_pid, :shutdown)
      Logger.info("Test server supervisor stopped.")
    end

    # 10. Exit with appropriate status code
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

  defp calculate_paths(ts_test_script) do
    app_path = Mix.Project.app_path()
    lib_dir = Path.dirname(app_path)
    env_dir = Path.dirname(lib_dir)
    build_dir = Path.dirname(env_dir)
    root_dir = Path.dirname(build_dir)
    client_test_dir = Path.join(root_dir, "typescript-client-test")
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

  defp run_ts_test(client_test_dir, ts_script_full_path, port, port_env_var) do
    # Use full path for script
    ts_script_arg = Path.relative_to(ts_script_full_path, client_test_dir)

    Mix.shell().info("Running TypeScript client test: #{ts_script_arg} against port #{port}...")
    env = %{port_env_var => Integer.to_string(port)}
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
