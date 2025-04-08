defmodule MCP.Server.Macros do
  @moduledoc """
  Macros for defining MCP tools and resources within an MCP.Server implementation.
  """
  require Logger

  defmacro __using__(_opts) do
    quote do
      import MCP.Server.Macros
      Module.register_attribute(__MODULE__, :mcp_tools, accumulate: true)
      @before_compile MCP.Server.Macros
    end
  end

  @doc """
  Defines an MCP tool.
  """
  defmacro tool(name, schema, do: block) do
    # Evaluate schema at compile time if it's a module attribute
    schema_ast = Macro.expand(schema, __CALLER__)

    # Generate the tool implementation function name
    tool_impl_name = String.to_atom("__tool_impl_#{name}")

    quote do
      # Define the implementation function with unhygienic variables
      defp unquote(tool_impl_name)(session_id, request_id, arguments) do
        var!(session_id) = session_id
        var!(request_id) = request_id
        var!(arguments) = arguments
        unquote(block)
      end

      # Extract description at compile time if we can
      description = case unquote(schema_ast) do
        %{"description" => desc} when is_binary(desc) -> desc
        _ -> "Tool #{unquote(name)}"
      end

      # Register the tool
      @mcp_tools {unquote(name), %{
        name: unquote(name),
        schema: unquote(schema_ast),
        description: description,
        impl: unquote(tool_impl_name)
      }}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # For debugging - inspect registered tools
    registered_tools = Module.get_attribute(env.module, :mcp_tools)
    require Logger

    # Debug output that will print during compile time
    IO.puts("Registered tools in module #{env.module}: #{inspect(registered_tools, pretty: true)}")

    quote do
      # Log the registered tools at runtime when the module loads
      @registered_tools_count length(@mcp_tools)
      Logger.info("Module #{__MODULE__} has #{@registered_tools_count} tools registered via macros")

      for {name, _definition} <- @mcp_tools do
        Logger.info("Tool registered: #{name}")
      end

      # List tools implementation
      @impl MCP.ServerBehaviour
      def handle_list_tools(session_id, request_id, _params) do
        Logger.debug("Called handle_list_tools", session_id: session_id, request_id: request_id)
        Logger.debug("Available tools from module attribute count: #{length(@mcp_tools)}")

        tools = for {name, definition} <- @mcp_tools do
          # Ensure schema is a standard Elixir map (not AST or other structures)
          schema = case definition.schema do
            %{} = s ->
              Logger.debug("Tool #{name} has valid schema map")
              s  # Already a map
            other ->
              Logger.warning("Tool #{name} has unexpected schema format: #{inspect(other)}")
              # Provide a fallback schema structure
              %{
                "type" => "object",
                "description" => "Generic tool",
                "properties" => %{},
                "required" => []
              }
          end

          # Build the tool description to return to the client
          tool_description = %{
            name: name,
            description: definition.description,
            inputSchema: schema
          }

          Logger.debug("Added tool to response: #{name}")
          tool_description
        end

        Logger.info("Returning #{length(tools)} tools from handle_list_tools",
          session_id: session_id,
          request_id: request_id,
          tools: inspect(Enum.map(tools, & &1.name))
        )

        {:ok, %{tools: tools}}
      end

      # Tool call implementation
      @impl MCP.ServerBehaviour
      def handle_tool_call(session_id, request_id, tool_name, arguments) do
        Logger.debug("Handling tool call: #{tool_name}", session_id: session_id, request_id: request_id)

        # Find the tool
        tool_entry = Enum.find(@mcp_tools, fn {name, _} -> name == tool_name end)

        case tool_entry do
          {_name, definition} ->
            # Validate arguments
            required = Map.get(definition.schema, "required", [])
            missing = required -- Map.keys(arguments)

            if Enum.empty?(missing) do
              # Convert string keys to atoms
              validated_args = Map.new(arguments, fn {k, v} -> {String.to_atom(k), v} end)
              apply(__MODULE__, definition.impl, [session_id, request_id, validated_args])
            else
              {:error, {MCP.Server.invalid_params(), "Missing required arguments: #{inspect(missing)}", nil}}
            end

          nil ->
            {:error, {MCP.Server.tool_not_found(), "Tool not found: #{tool_name}", nil}}
        end
      end
    end
  end
end
