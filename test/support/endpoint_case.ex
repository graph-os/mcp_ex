defmodule MCP.EndpointCase do
  @moduledoc """
  Case template for tests needing a running MCP.Endpoint.

  Starts the endpoint on a random port before each test and ensures
  it's stopped afterwards.

  Injects `:port` into the test context. Optionally starts Finch
  and injects `:finch_name` if `:start_finch` option is true.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import necessary test helpers
      import ExUnit.Assertions
      require Logger

      # Setup block to start endpoint and optionally Finch
      setup tags do
        # Start the endpoint
        {:ok, port} = MCP.EndpointCase.get_free_port()

        # Allow overriding endpoint opts via tags (use Map.get for tags map)
        default_endpoint_opts = [port: port, server: MCP.DefaultServer, host: {127, 0, 0, 1}, mode: :sse]
        endpoint_opts = Keyword.merge(default_endpoint_opts, Map.get(tags, :endpoint_opts, []))

        {:ok, endpoint_pid} = start_supervised({MCP.Endpoint, endpoint_opts})

        # Add delay for server binding
        Process.sleep(50)

        # Start Finch if requested by tag (use Map.get for tags map)
        finch_data =
          if Map.get(tags, :start_finch, false) do
            finch_name = "Finch.Test.#{System.unique_integer([:positive])}" |> String.to_atom()
            {:ok, finch_pid} = start_supervised({Finch, name: finch_name})
            %{finch_pid: finch_pid, finch_name: finch_name}
          else
            %{}
          end

        # Ensure proper shutdown using on_exit
        on_exit(fn ->
          Logger.debug("on_exit: Stopping endpoint_pid: #{inspect(endpoint_pid)}")
          is_endpoint_alive = Process.alive?(endpoint_pid)
          Logger.debug("on_exit: Is endpoint alive? #{is_endpoint_alive}")
          if is_endpoint_alive, do: Supervisor.stop(endpoint_pid, :shutdown, :infinity)

          if finch_pid = finch_data[:finch_pid] do
            Logger.debug("on_exit: Stopping finch_pid: #{inspect(finch_pid)}")
            is_finch_alive = Process.alive?(finch_pid)
            Logger.debug("on_exit: Is finch alive? #{is_finch_alive}")
            if is_finch_alive, do: Supervisor.stop(finch_pid, :shutdown, :infinity)
          end
        end)

        # Return context
        # Log the created context for debugging
        context = %{port: port} |> Map.merge(finch_data)
        # Logger.debug("EndpointCase setup complete. Context: #{inspect context}")
        {:ok, context}

      end
    end
  end

  # Helper to find a free port (moved here)
  def get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    {:ok, port}
  end
end
