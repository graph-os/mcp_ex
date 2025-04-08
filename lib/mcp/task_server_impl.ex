# lib/mcp/task_server_impl.ex
defmodule MCP.TaskServerImpl do
  @moduledoc """
  MCP Server implementation providing Mix task execution tools.
  """
  @behaviour MCP.ServerBehaviour

  require Logger
  # Import MCP.Server to access error codes
  import MCP.Server, only: [invalid_params: 0, internal_error: 0, method_not_found: 0]

  @default_timeout 5_000
  @default_test_timeout 120_000
  @protocol_version "2024-11-05" # Use the globally defined version

  # --- MCP.ServerBehaviour Callbacks ---

  @impl MCP.ServerBehaviour
  def start(_session_id), do: :ok # No specific session start needed

  @impl MCP.ServerBehaviour
  def handle_initialize(_session_id, _request_id, params) do
    Logger.info("[TaskServer] Received initialize request", client_params: params)
    # Simple initialize response, capabilities might be empty for this server
    {:ok, %{
      protocolVersion: @protocol_version,
      capabilities: %{ tools: %{} },
      serverInfo: %{
        name: "MCP Mix Task Server (Elixir)",
        version: Mix.Project.config()[:version] || "0.0.0"
      }
    }}
  end

  @impl MCP.ServerBehaviour
  def handle_ping(_session_id, _request_id) do
     {:ok, %{}} # Result content doesn't matter for ping
  end

  @impl MCP.ServerBehaviour
  def handle_list_tools(_session_id, _request_id, _params) do
    Logger.info("[TaskServer] Received list_tools request")
    tools = [
      %{
        name: "run_mix_task",
        description: "Runs an arbitrary Mix task. Use 'sync: true' to wait for completion (up to timeout). Default timeout is 5s, except for 'mix test' which defaults to 120s.",
        inputSchema: %{
          "type" => "object",
          "properties" => %{
            "task" => %{"type" => "string", "description" => "The mix task and arguments (e.g., 'deps.get', 'test --trace')"},
            "sync" => %{"type" => "boolean", "description" => "Wait for task completion (true) or run with timeout (false, default)."},
            "timeout" => %{"type" => "integer", "description" => "Timeout in milliseconds."}
          },
          "required" => ["task"]
        }
        # Output is defined as content items in the result
      }
    ]
    {:ok, %{tools: tools}}
  end

  @impl MCP.ServerBehaviour
  def handle_tool_call(session_id, request_id, "run_mix_task", arguments) do
    Logger.info("[TaskServer] Received tools/call for run_mix_task", session: session_id, req: request_id, args: arguments)

    task_string = Map.get(arguments, "task")
    is_sync = Map.get(arguments, "sync", false)

    if is_nil(task_string) || String.trim(task_string) == "" do
      Logger.error("[TaskServer] Missing or empty 'task' parameter")
      {:error, {invalid_params(), "Missing or empty 'task' parameter", nil}}
    else
      [task_name | task_args] = String.split(task_string)
      default_timeout = if task_name == "test", do: @default_test_timeout, else: @default_timeout
      effective_timeout = Map.get(arguments, "timeout", default_timeout)

      Logger.info("[TaskServer] Running task: mix #{task_string}, sync: #{is_sync}, timeout: #{effective_timeout}")

      if is_sync do
        run_sync(task_name, task_args, effective_timeout)
      else
        run_async(task_name, task_args, effective_timeout)
      end
    end
  end

  # Fallback for unknown tool names
  def handle_tool_call(session_id, _request_id, tool_name, _arguments) do
    Logger.error("[TaskServer] Unknown tool requested: #{tool_name}", session: session_id)
    {:error, {method_not_found(), "Tool not found: #{tool_name}", nil}}
  end

  # --- Task Execution Logic (extracted and adapted) ---

  defp run_sync(task_name, task_args, timeout) do
    cmd = System.find_executable("mix")
    unless cmd do
      Logger.error("[TaskServer] Error: 'mix' command not found in PATH.")
      {:error, {internal_error(), "'mix' command not found in PATH", nil}}
    else
      args = [task_name | task_args]
      port_opts = [:binary, :exit_status, :use_stdio, {:args, args}, {:cd, File.cwd!()}, {:env, [{"HOME", System.user_home!()}]}]
      port = Port.open({:spawn_executable, cmd}, port_opts)
      Logger.info("[TaskServer] Opened port for sync task: mix #{task_name}")

      output_acc = collect_output(port, timeout, "")

      case output_acc do
         {:ok, output, exit_status} ->
           Logger.info("[TaskServer] Sync task finished. Exit: #{exit_status}")
           content = [%{ type: "text", text: output, _meta: %{ exit_status: exit_status } }]
           {:ok, %{content: content}}
         {:error, :timeout, output} ->
           Logger.error("[TaskServer] Sync task timed out. Output length: #{String.length(output)}")
           Port.close(port)
           {:error, {internal_error(), "Task timed out after #{timeout}ms", %{output: output}}}
         {:error, reason, output} ->
           Logger.error("[TaskServer] Sync task error: #{inspect reason}. Output length: #{String.length(output)}")
           {:error, {internal_error(), "Task error: #{inspect reason}", %{output: output}}}
      end
    end
  end

  defp collect_output(port, timeout, acc_output) do
     receive do
       {^port, {:data, data_binary}} ->
         collect_output(port, timeout, acc_output <> data_binary)
       {^port, {:exit_status, status}} ->
         {:ok, acc_output, status}
     after
       timeout -> {:error, :timeout, acc_output}
     end
  end

  defp run_async(task_name, task_args, timeout) do
     cmd = System.find_executable("mix")
     unless cmd do
       Logger.error("[TaskServer] Error: 'mix' command not found in PATH.")
       {:error, {internal_error(), "'mix' command not found in PATH", nil}}
     else
       args = [task_name | task_args]
       Logger.info("[TaskServer] Running async: #{cmd} #{Enum.join(args, " ")} with timeout #{timeout}")
       cmd_opts = [stderr_to_stdout: true, timeout: timeout, cd: File.cwd!(), env: %{"HOME" => System.user_home!()}]

       try do
         case System.cmd(cmd, args, cmd_opts) do
           {output, exit_status} ->
             Logger.info("[TaskServer] Async task finished. Exit: #{exit_status}")
             content = [%{ type: "text", text: output, _meta: %{ exit_status: exit_status } }]
             {:ok, %{content: content}}
         end
       catch
         :exit, {:timeout, _} ->
           Logger.error("[TaskServer] Async task timed out.")
           {:error, {internal_error(), "Task timed out after #{timeout}ms", nil}}
         kind, reason ->
           stack = Exception.format_stacktrace(__STACKTRACE__)
           Logger.error("[TaskServer] Async task failed with exception: #{kind} - #{inspect reason}\n#{stack}")
           {:error, {internal_error(), "Task failed: #{kind} - #{inspect reason}", %{stacktrace: stack}}}
       end
     end
  end

  # --- Default Callbacks (Delegating to MCP.Server for unimplemented ones) ---
  # This assumes MCP.Server provides default implementations or appropriate errors.
  # Remove any that TaskServerImpl *does* implement fully above.

  # handle_initialize is implemented
  # handle_ping is implemented
  # handle_list_tools is implemented
  # handle_tool_call is implemented

  @impl MCP.ServerBehaviour
  def handle_list_resources(session_id, request_id, params), do: MCP.Server.handle_list_resources(session_id, request_id, params)

  @impl MCP.ServerBehaviour
  def handle_read_resource(session_id, request_id, params), do: MCP.Server.handle_read_resource(session_id, request_id, params)

  @impl MCP.ServerBehaviour
  def handle_list_prompts(session_id, request_id, params), do: MCP.Server.handle_list_prompts(session_id, request_id, params)

  @impl MCP.ServerBehaviour
  def handle_get_prompt(session_id, request_id, params), do: MCP.Server.handle_get_prompt(session_id, request_id, params)

  @impl MCP.ServerBehaviour
  def handle_complete(session_id, request_id, params), do: MCP.Server.handle_complete(session_id, request_id, params)

  @impl MCP.ServerBehaviour
  def handle_notification(session_id, method, params, session_data), do: MCP.Server.handle_notification(session_id, method, params, session_data)
end
