defmodule MCP.EndpointPlug do
  @moduledoc """
  Plug responsible for routing requests based on a path prefix.

  It receives the `:path_prefix` in its options during initialization.
  In `call/2`, it checks if the request path matches the prefix.
  - If it matches (or prefix is empty), it adjusts the conn's path info
    and script name, then calls `MCP.Router.call/2` directly.
  - Otherwise, it sends a 404 response.
  """
  @behaviour Plug
  require Logger

  @impl Plug
  def init(opts) do
    opts
  end

  @impl Plug
  def call(conn, opts) do
    path_prefix = opts[:path_prefix] # Already normalized by MCP.Endpoint
    request_path = conn.request_path

    cond do
      # Case 1: No prefix, call router directly
      path_prefix == "" ->
        # Logger.debug("[EndpointPlug] No prefix, calling MCP.Router for path: #{request_path}")
        MCP.Router.call(conn, MCP.Router.init([]))

      # Case 2: Prefix matches the start of the request path
      String.starts_with?(request_path, path_prefix) ->
        # Calculate path adjustments
        stripped_request_path = String.trim_leading(request_path, path_prefix)
        # Ensure stripped path starts with /
        stripped_request_path = if stripped_request_path == "", do: "/", else: stripped_request_path

        # path_info should be the segments *after* the script_name
        new_path_info = String.split(stripped_request_path, "/", trim: true)

        # script_name should be the segments *before* the path_info
        new_script_name = String.split(path_prefix, "/", trim: true)

        # Update conn
        conn = %{conn |
          request_path: stripped_request_path,
          path_info: new_path_info,
          script_name: new_script_name
        }

        # Logger.debug("[EndpointPlug] Prefix '#{path_prefix}' matched. Calling MCP.Router with path_info: #{inspect new_path_info}, script_name: #{inspect new_script_name}")
        MCP.Router.call(conn, MCP.Router.init([]))

      # Case 3: Prefix set, but does not match
      true ->
        Logger.debug("[EndpointPlug] Request path '#{request_path}' does not match prefix '#{path_prefix}', sending 404")
        conn
        |> Plug.Conn.send_resp(404, "Not Found")
        |> Plug.Conn.halt()
    end
  end

end
