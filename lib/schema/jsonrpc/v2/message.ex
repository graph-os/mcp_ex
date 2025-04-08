defmodule JSONRPC.V2.Message do
  @moduledoc false

  @jsonrpc_version "2.0"
  def jsonrpc_version, do: @jsonrpc_version

  alias JSONRPC.V2.{Request, Notification, SuccessResponse, ErrorResponse}

  @type t :: Request.t() | Notification.t() | SuccessResponse.t() | ErrorResponse.t()

  def schema do
    %{
      "oneOf" => [
        JSONRPC.V2.Request.schema(),
        JSONRPC.V2.Notification.schema(),
        JSONRPC.V2.SuccessResponse.schema(),
        JSONRPC.V2.ErrorResponse.schema()
      ]
    }
  end

  def decode_request(payload, schema) do
    Request.decode(payload, schema)
  end

  def decode_notification(payload, schema) do
    Notification.decode(payload, schema)
  end

  def decode_success_response(payload, schema) do
    SuccessResponse.decode(payload, schema)
  end

  def decode_error_response(payload, schema) do
    ErrorResponse.decode(payload, schema)
  end
end
