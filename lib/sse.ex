defmodule SSE do
  @moduledoc """
  Server-Sent Events (SSE) implementation for the Model Context Protocol (MCP).

  This module provides the main entry point for the SSE system and registers
  the connection registry for managing client connections.
  """

  use Application

  @impl true
  def start(_type, _args) do
    case already_started?() do
      true ->
        {:ok, self()}

      false ->
        children = [
          SSE.ConnectionRegistry
        ]

        opts = [strategy: :one_for_one, name: SSE.Supervisor]
        Supervisor.start_link(children, opts)
    end
  end

  @doc """
  Starts the SSE supervision tree.
  This is useful for testing and development.
  In production, you should add SSE to your application's dependencies.
  """
  def start do
    Application.ensure_all_started(:mcp)
  end

  # Check if the registry is already started
  defp already_started? do
    case Process.whereis(SSE.Supervisor) do
      nil -> false
      _pid -> true
    end
  end

  @doc """
  Logs a message with the appropriate log level based on MCP configuration.

  ## Parameters

  * `level` - The log level (`:debug`, `:info`, `:warn`, `:error`)
  * `message` - The message to log
  * `metadata` - Additional metadata to include in the log
  """
  def log(level, message, metadata \\ []) do
    if should_log?(level) do
      require Logger
      Logger.log(level, message, metadata)
    end
  end

  # Checks if a message at the given level should be logged
  defp should_log?(level) do
    log_levels = %{
      debug: 0,
      info: 1,
      warn: 2,
      error: 3
    }

    configured_level = MCP.log_level()

    log_levels[level] >= log_levels[configured_level]
  end
end
