defmodule Schemas.JSONRPC.V2 do
  @moduledoc """
  JSON-RPC 2.0 schemas for MCP.
  """

  @version "2.0"

  @doc """
  Returns the JSON-RPC version.
  """
  def version, do: @version
end

defmodule JSONRPC2 do
  @moduledoc false
  def error_codes do
    [
      parser_error: -32700,
      invalid_request: -32600,
      method_not_found: -32601,
      invalid_params: -32602,
      internal_error: -32603
    ]
  end
end