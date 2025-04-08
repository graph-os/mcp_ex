defmodule MCP.Message do
  @moduledoc false

  alias MCP.Message.Fragments
  use MCP.Messages.Macros

  @versions ["2024-11-05"]
  def latest_version, do: @versions |> List.first()
  def supported_versions, do: @versions

  defguard is_version(version) when version in @versions

  @spec is_mcp_version?(String.t()) :: boolean()
  def is_mcp_version?(version) when is_binary(version) do
    version in @versions
  end

  # TODO: Ensure that we support all methods and only valid methods
  @methods [
    "initialize",
    "ping",
    "resources/list",
    "resources/read",
    "resources/templates/list",
    "resources/subscribe",
    "resources/unsubscribe",
    "tools/list",
    "tools/call",
    "prompts/list",
    "prompts/get",
    "completion/complete",
    "logging/setLevel",
    "sampling/createMessage",
    "roots/list"
  ]
  def supported_methods, do: @methods

  # Initialize Request
  defmessage "InitializeRequest", "2024-11-05", "initialize" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["initialize"]},
        "params" => %{
          "type" => "object",
          "required" => ["protocolVersion", "capabilities", "clientInfo"],
          "properties" => %{
            "protocolVersion" => %{"type" => "string"},
            "capabilities" => Fragments.client_capabilities("2024-11-05"),
            "clientInfo" => Fragments.implementation("2024-11-05"),
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Initialize Result
  defmessage "InitializeResult", "2024-11-05", "initialize/result" do
    %{
      "type" => "object",
      "required" => ["protocolVersion", "capabilities", "serverInfo"],
      "properties" => %{
        "protocolVersion" => %{"type" => "string"},
        "capabilities" => Fragments.server_capabilities("2024-11-05"),
        "serverInfo" => Fragments.implementation("2024-11-05"),
        "instructions" => %{"type" => "string"},
        "_meta" => %{"type" => "object"}
      }
    }
  end

  def initialize_result(server_name, server_version, server_capabilities, %{}, instructions \\ "", _meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "protocolVersion" => latest_version(),
      "capabilities" => server_capabilities,
      "serverInfo" => %{
        "name" => server_name,
        "version" => server_version
      },
      "instructions" => instructions
    }
  end



  # Ping Request
  defmessage "PingRequest", "2024-11-05", "ping" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["ping"]},
        "params" => %{"type" => "object"}
      }
    }
  end

  # Ping Result (Empty Result)
  defmessage "PingResult", "2024-11-05", "ping/result" do
    %{
      "type" => "object",
      "properties" => %{
        "_meta" => %{"type" => "object"}
      }
    }
  end

  def ping_result(meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "_meta" => meta
    }
  end

  # List Resources Request
  defmessage "ListResourcesRequest", "2024-11-05", "resources/list" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["resources/list"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "cursor" => %{"type" => "string"},
            "count" => %{"type" => "integer"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # List Resources Result
  defmessage "ListResourcesResult", "2024-11-05", "resources/list/result" do
    %{
      "type" => "object",
      "required" => ["resources"],
      "properties" => %{
        "resources" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["uri"],
            "properties" => %{
              "uri" => %{"type" => "string"},
              "displayName" => %{"type" => "string"},
              "description" => %{"type" => "string"},
              "mimeType" => %{"type" => "string"}
            }
          }
        },
        "cursor" => %{"type" => "string"},
        "_meta" => %{"type" => "object"}
      }
    }
  end

  @spec list_resources_result([map()], String.t(), map()) :: map()
  def list_resources_result(resources, cursor \\ "", meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "resources" => resources,
      "cursor" => cursor,
      "_meta" => meta
    }
  end

  # Read Resource Request
  defmessage "ReadResourceRequest", "2024-11-05", "resources/read" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["resources/read"]},
        "params" => %{
          "type" => "object",
          "required" => ["uri"],
          "properties" => %{
            "uri" => %{"type" => "string"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Read Resource Result
  defmessage "ReadResourceResult", "2024-11-05", "resources/read/result" do
    %{
      "type" => "object",
      "required" => ["contents"],
      "properties" => %{
        "contents" => Fragments.resource_contents("2024-11-05"),
        "_meta" => %{"type" => "object"}
      }
    }
  end

  def read_resource_result(contents, meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "contents" => contents,
      "_meta" => meta
    }
  end

  # List Resource Templates Request
  defmessage "ListResourceTemplatesRequest", "2024-11-05", "resources/templates/list" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["resources/templates/list"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # List Resource Templates Result
  defmessage "ListResourceTemplatesResult", "2024-11-05", "resources/templates/list/result" do
    %{
      "type" => "object",
      "required" => ["templates"],
      "properties" => %{
        "templates" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["template"],
            "properties" => %{
              "template" => %{"type" => "string"},
              "description" => %{"type" => "string"}
            }
          }
        },
        "_meta" => %{"type" => "object"}
      }
    }
  end

  # Subscribe Request
  defmessage "SubscribeRequest", "2024-11-05", "resources/subscribe" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["resources/subscribe"]},
        "params" => %{
          "type" => "object",
          "required" => ["uri"],
          "properties" => %{
            "uri" => %{"type" => "string"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Unsubscribe Request
  defmessage "UnsubscribeRequest", "2024-11-05", "resources/unsubscribe" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["resources/unsubscribe"]},
        "params" => %{
          "type" => "object",
          "required" => ["uri"],
          "properties" => %{
            "uri" => %{"type" => "string"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # List Tools Request
  defmessage "ListToolsRequest", "2024-11-05", "tools/list" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["tools/list"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "cursor" => %{"type" => "string"},
            "count" => %{"type" => "integer"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # List Tools Result
  defmessage "ListToolsResult", "2024-11-05", "tools/list/result" do
    %{
      "type" => "object",
      "required" => ["tools"],
      "properties" => %{
        "tools" => %{
          "type" => "array",
          "items" => Fragments.tool("2024-11-05")
        },
        "nextCursor" => %{"type" => "string"}, # Changed "cursor" to "nextCursor"
        "_meta" => %{"type" => "object"}
      }
    }
  end

  def list_tools_result(tools, next_cursor \\ nil, meta \\ %{}) do # Changed arg name and default
    %{
      "jsonrpc" => "2.0",
      "tools" => tools,
      "nextCursor" => next_cursor, # Changed key name
      "_meta" => meta
    }
    # Note: The dispatcher already filters nil values, so sending nil here is fine.
  end

  # Call Tool Request
  defmessage "CallToolRequest", "2024-11-05", "tools/call" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["tools/call"]},
        "params" => %{
          "type" => "object",
          "required" => ["name", "arguments"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "arguments" => %{"type" => "object"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Call Tool Result
  defmessage "CallToolResult", "2024-11-05", "tools/call/result" do
    %{
      "type" => "object",
      "required" => ["content"], # Added content as required
      "properties" => %{
        "content" => %{ # Changed "result" to "content" and defined its type
          "type" => "array",
          "items" => %{
            "oneOf" => [
              Fragments.text_content("2024-11-05"),
              Fragments.image_content("2024-11-05")
              # Removed Fragments.audio_content and Fragments.embedded_resource
            ]
          }
        },
        "isError" => %{"type" => "boolean"}, # Added isError field
        "_meta" => %{"type" => "object"}
      }
    }
  end

  # Note: The helper function call_tool_result is no longer used by the dispatcher.
  # The dispatcher now constructs the struct directly. We can leave the old helper
  # or remove it, but it's not causing the current issue.
  # Keeping it for now to minimize changes.
  def call_tool_result(result, meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "result" => result, # This helper is now inconsistent with the schema above
      "_meta" => meta
    }
  end

  # List Prompts Request
  defmessage "ListPromptsRequest", "2024-11-05", "prompts/list" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["prompts/list"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "cursor" => %{"type" => "string"},
            "count" => %{"type" => "integer"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # List Prompts Result
  defmessage "ListPromptsResult", "2024-11-05", "prompts/list/result" do
    %{
      "type" => "object",
      "required" => ["prompts"],
      "properties" => %{
        "prompts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "description" => %{"type" => "string"}
            }
          }
        },
        "cursor" => %{"type" => "string"},
        "_meta" => %{"type" => "object"}
      }
    }
  end

  def list_prompts_result(prompts, cursor \\ "", meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "prompts" => prompts,
      "cursor" => cursor,
      "_meta" => meta
    }
  end

  # Get Prompt Request
  defmessage "GetPromptRequest", "2024-11-05", "prompts/get" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["prompts/get"]},
        "params" => %{
          "type" => "object",
          "required" => ["name"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Get Prompt Result
  defmessage "GetPromptResult", "2024-11-05", "prompts/get/result" do
    %{
      "type" => "object",
      "required" => ["name", "messages"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "messages" => %{
          "type" => "array",
          "items" => Fragments.prompt_message("2024-11-05")
        },
        "arguments" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "description" => %{"type" => "string"},
              "type" => %{"enum" => ["string", "number", "boolean", "array", "object"]}
            }
          }
        },
        "_meta" => %{"type" => "object"}
      }
    }
  end

  def get_prompt_result(name, messages, arguments \\ [], description \\ "", meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "name" => name,
      "messages" => messages,
      "arguments" => arguments,
      "description" => description,
      "_meta" => meta
    }
  end

  # Complete Request
  defmessage "CompleteRequest", "2024-11-05", "completion/complete" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["completion/complete"]},
        "params" => %{
          "type" => "object",
          "required" => ["messages"],
          "properties" => %{
            "messages" => %{
              "type" => "array",
              "items" => Fragments.prompt_message("2024-11-05")
            },
            "model" => %{"type" => "string"},
            "options" => %{"type" => "object"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end



  # Complete Result
  defmessage "CompleteResult", "2024-11-05", "completion/complete/result" do
    %{
      "type" => "object",
      "required" => ["completion"],
      "properties" => %{
        "completion" => Fragments.prompt_message("2024-11-05"),
        "_meta" => %{"type" => "object"}
      }
    }
  end

  def complete_result(completion, meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "completion" => completion,
      "_meta" => meta
    }
  end

  # Set Level Request
  defmessage "SetLevelRequest", "2024-11-05", "logging/setLevel" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["logging/setLevel"]},
        "params" => %{
          "type" => "object",
          "required" => ["level"],
          "properties" => %{
            "level" => %{"enum" => ["trace", "debug", "info", "warn", "error"]},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Create Message Request
  defmessage "CreateMessageRequest", "2024-11-05", "sampling/createMessage" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["sampling/createMessage"]},
        "params" => %{
          "type" => "object",
          "required" => ["messages"],
          "properties" => %{
            "messages" => %{
              "type" => "array",
              "items" => Fragments.prompt_message("2024-11-05")
            },
            "temperature" => %{"type" => "number"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Create Message Result
  defmessage "CreateMessageResult", "2024-11-05", "sampling/createMessage/result" do
    %{
      "type" => "object",
      "required" => ["message"],
      "properties" => %{
        "message" => Fragments.prompt_message("2024-11-05"),
        "_meta" => %{"type" => "object"}
      }
    }
  end

  # List Roots Request
  defmessage "ListRootsRequest", "2024-11-05", "roots/list" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["roots/list"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # List Roots Result
  defmessage "ListRootsResult", "2024-11-05", "roots/list/result" do
    %{
      "type" => "object",
      "required" => ["roots"],
      "properties" => %{
        "roots" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["name", "rootUri"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "rootUri" => %{"type" => "string"},
              "description" => %{"type" => "string"}
            }
          }
        },
        "_meta" => %{"type" => "object"}
      }
    }
  end

  # Initialized Notification
  defmessage "InitializedNotification", "2024-11-05", "notifications/initialized" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/initialized"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Progress Notification
  defmessage "ProgressNotification", "2024-11-05", "notifications/progress" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/progress"]},
        "params" => %{
          "type" => "object",
          "required" => ["token", "value"],
          "properties" => %{
            "token" => %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]},
            "value" => %{},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Cancelled Notification
  defmessage "CancelledNotification", "2024-11-05", "notifications/cancelled" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/cancelled"]},
        "params" => %{
          "type" => "object",
          "required" => ["id"],
          "properties" => %{
            "id" => %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Resource List Changed Notification
  defmessage "ResourceListChangedNotification", "2024-11-05", "notifications/resources/list_changed" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/resources/list_changed"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Resource Updated Notification
  defmessage "ResourceUpdatedNotification", "2024-11-05", "notifications/resources/updated" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/resources/updated"]},
        "params" => %{
          "type" => "object",
          "required" => ["uri"],
          "properties" => %{
            "uri" => %{"type" => "string"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Tool List Changed Notification
  defmessage "ToolListChangedNotification", "2024-11-05", "notifications/tools/list_changed" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/tools/list_changed"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Prompt List Changed Notification
  defmessage "PromptListChangedNotification", "2024-11-05", "notifications/prompts/list_changed" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/prompts/list_changed"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Logging Message Notification
  defmessage "LoggingMessageNotification", "2024-11-05", "notifications/message" do
    %{
      "type" => "object",
      "required" => ["method", "params"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/message"]},
        "params" => %{
          "type" => "object",
          "required" => ["level", "message"],
          "properties" => %{
            "level" => %{"enum" => ["trace", "debug", "info", "warn", "error"]},
            "message" => %{"type" => "string"},
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end

  # Roots List Changed Notification
  defmessage "RootsListChangedNotification", "2024-11-05", "notifications/roots/list_changed" do
    %{
      "type" => "object",
      "required" => ["method"],
      "properties" => %{
        "method" => %{"enum" => ["notifications/roots/list_changed"]},
        "params" => %{
          "type" => "object",
          "properties" => %{
            "_meta" => %{"type" => "object"}
          }
        }
      }
    }
  end
end
