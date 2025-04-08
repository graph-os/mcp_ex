defmodule JSONRPC.V2.ErrorResponse do
  @moduledoc false

  @jsonrpc_version "2.0"

  @type id :: String.t() | non_neg_integer()
  @type method :: String.t()
  @type error :: map()
  @type schema :: atom()

  @type t :: %__MODULE__{
    jsonrpc: String.t(),
    id: id(),
    error: error()
  }

  @required_keys [:jsonrpc, :id, :error, :__schema__]
  @optional_keys []
  @keys @required_keys ++ @optional_keys

  @enforce_keys @required_keys
  defstruct @keys

  def decode(payload, schema \\ :jsonrpc_error_response) do
    %__MODULE__{
      jsonrpc: @jsonrpc_version,
      id: Keyword.get(payload, :id),
      error: Keyword.get(payload, :error),
      __schema__: schema
    }
  end

  def request_id_schema() do
    %{
      "oneOf" => [
        %{"type" => "string"},
        %{"type" => "integer"}
      ]
    }
  end

  def error_schema() do
    %{
      "type" => "object",
      "required" => ["code", "message"],
      "properties" => %{
        "code" => %{"type" => "integer"},
        "message" => %{"type" => "string"},
        "data" => %{}
      }
    }
  end

  def schema do
    %{
      "type" => "object",
      "required" => ["jsonrpc", "id", "error"],
      "properties" => %{
        "jsonrpc" => %{"enum" => [@jsonrpc_version]},
        "id" => request_id_schema(),
        "error" => error_schema()
      },
      "additionalProperties" => false
    }
  end

  def validate(message) do
    if ExJsonSchema.Validator.valid?(schema(), message) do
      {:ok, message}
    else
      {:error, "Invalid message format"}
    end
  end
end
