defmodule MCP do
  @moduledoc """
  Model Context Protocol (MCP) for Elixir

  This module provides the main entry point for the MCP system,
  including configuration and application management.
  """

  @doc """
  Returns the current configuration for the MCP server.

  ## Options

  * `:log_level` - The log level for the MCP server (`:debug`, `:info`, `:warn`, `:error`). Default: `:info`
  * `:supported_versions` - List of supported protocol versions. Default: [MCP.Message.latest_version()]
  """
  def config do
    Application.get_env(:mcp, MCP, [])
    |> Keyword.put_new(:log_level, :info)
    |> Keyword.put_new(:supported_versions, [MCP.Message.latest_version()])
  end

  @doc """
  Returns the current log level for the MCP server.
  """
  def log_level do
    config()[:log_level]
  end

  @doc """
  Returns a list of supported protocol versions.
  """
  def supported_versions do
    config()[:supported_versions]
  end

  @doc """
  Checks if a given protocol version is supported.
  """
  def supports_version?(version) do
    version in supported_versions()
  end
end
