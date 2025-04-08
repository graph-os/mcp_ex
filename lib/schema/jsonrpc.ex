defmodule Schemas.JSONRPC do
  @moduledoc """
  JSON-RPC version management and context module.
  """

  @latest_version Schemas.JSONRPC.V2.version()

  @doc """
  Returns the latest supported JSON-RPC version.
  """
  @spec latest_protocol_version() :: String.t()
  def latest_protocol_version(), do: @latest_version
end
