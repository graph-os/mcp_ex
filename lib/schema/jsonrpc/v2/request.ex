defmodule JSONRPC.V2.Request do
  @moduledoc false

  @jsonrpc_version "2.0"

  @type id :: String.t() | non_neg_integer()
  @type method :: String.t()
  @type params :: map()
  @type schema :: atom()

  @type t :: %__MODULE__{
          jsonrpc: String.t(),
          id: id(),
          method: method(),
          params: params() | nil,
          __schema__: schema()
        }

  @required_keys [:jsonrpc, :id, :method, :__schema__]
  @optional_keys [:params]
  @keys @required_keys ++ @optional_keys

  @enforce_keys @required_keys
  defstruct @keys

  def decode(payload, schema \\ :jsonrpc_request) do
    %__MODULE__{
      jsonrpc: @jsonrpc_version,
      id: Keyword.get(payload, :id),
      method: Keyword.get(payload, :method),
      params: Keyword.get(payload, :params),
      __schema__: schema
    }
  end

  def encode(%__MODULE__{jsonrpc: jsonrpc, id: id, method: method, params: params}) do
    %{
      "jsonrpc" => jsonrpc,
      "id" => id,
      "method" => method,
      "params" => params
    }
  end

  def schema do
    %{
      "type" => "object",
      "required" => ["jsonrpc", "id", "method"],
      "properties" => %{
        "jsonrpc" => %{"enum" => [@jsonrpc_version]},
        "id" => %{
          "oneOf" => [
            %{"type" => "string"},
            %{"type" => "integer"}
          ]
        },
        "method" => %{"type" => "string"},
        "params" => %{"type" => "object"}
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
