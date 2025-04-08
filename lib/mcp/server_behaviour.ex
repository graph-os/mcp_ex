defmodule MCP.ServerBehaviour do
  @moduledoc """
  Behaviour specification for MCP (Model Context Protocol) servers.

  This module defines the callback specifications required for implementing a
  compliant MCP server, providing the foundation for the `MCP.Server` module.
  """

  @doc """
  Initialize the server for a specific session.
  """
  @callback start(session_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Process an incoming message from a client.
  """
  @callback handle_message(session_id :: String.t(), message :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Handle a ping request.
  """
  @callback handle_ping(session_id :: String.t(), request_id :: term()) :: {:ok, map()} | {:error, term()}

  @doc """
  Process an initialize request from a client.
  """
  @callback handle_initialize(session_id :: String.t(), request_id :: term(), params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  List available tools.
  """
  @callback handle_list_tools(session_id :: String.t(), request_id :: term(), params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Handle a tool call request.
  """
  @callback handle_tool_call(session_id :: String.t(), request_id :: term(), tool_name :: String.t(), arguments :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  List available resources.
  """
  @callback handle_list_resources(session_id :: String.t(), request_id :: term(), params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Read a specific resource.
  """
  @callback handle_read_resource(session_id :: String.t(), request_id :: term(), params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  List available prompts.
  """
  @callback handle_list_prompts(session_id :: String.t(), request_id :: term(), params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Get a specific prompt.
  """
  @callback handle_get_prompt(session_id :: String.t(), request_id :: term(), params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Handle a completion request.
  """
  @callback handle_complete(session_id :: String.t(), request_id :: term(), params :: map()) :: {:ok, map()} | {:error, term()}
end
