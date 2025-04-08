defmodule JSONRPC.V2.SuccessResponse do
  @moduledoc false

  @jsonrpc_version "2.0"

  @type id :: String.t() | non_neg_integer()
  @type method :: String.t()
  @type result :: map()
  @type schema :: atom()

  @type t :: %__MODULE__{
          jsonrpc: String.t(),
          id: id(),
          result: result()
        }

  @required_keys [:jsonrpc, :id, :result, :__schema__]
  @optional_keys []
  @keys @required_keys ++ @optional_keys

  @enforce_keys @required_keys
  defstruct @keys

  def decode(payload, schema \\ :jsonrpc_success_response) do
    %__MODULE__{
      jsonrpc: @jsonrpc_version,
      id: Keyword.get(payload, :id),
      result: Keyword.get(payload, :result),
      __schema__: schema
    }
  end

  def encode(%__MODULE__{jsonrpc: jsonrpc, id: id, result: result}) do
    %{
      "jsonrpc" => jsonrpc,
      "id" => id,
      "result" => result
    }
  end

  def request_id() do
    %{
      "oneOf" => [
        %{"type" => "string"},
        %{"type" => "integer"}
      ]
    }
  end

  def result() do
    %{
      "type" => "object",
      "additionalProperties" => true
    }
  end

  def schema() do
    %{
      "type" => "object",
      "required" => ["jsonrpc", "id", "result"],
      "properties" => %{
        "jsonrpc" => %{"enum" => [@jsonrpc_version]},
        "id" => request_id(),
        "result" => result()
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
