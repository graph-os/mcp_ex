defmodule MCP.Message.Fragments do
  @moduledoc """
  Provides JSON schema fragments for MCP message validation.
  Contains reusable components for building message schemas with version support.
  """

  def client_capabilities("2024-11-05") do
    %{
      "type" => "object",
      "properties" => %{
        "experimental" => %{"type" => "object"},
        "sampling" => %{"type" => "object"},
        "roots" => %{
          "type" => "object",
          "properties" => %{
            "listChanged" => %{"type" => "boolean"}
          }
        }
      },
      "additionalProperties" => true
    }
  end

  def implementation("2024-11-05") do
    %{
      "type" => "object",
      "required" => ["name", "version"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "version" => %{"type" => "string"}
      },
      "additionalProperties" => true
    }
  end

  def server_capabilities("2024-11-05") do
    %{
      "type" => "object",
      "properties" => %{
        "experimental" => %{"type" => "object"},
        "logging" => %{"type" => "object"},
        "prompts" => %{
          "type" => "object",
          "properties" => %{
            "listChanged" => %{"type" => "boolean"}
          }
        },
        "resources" => %{
          "type" => "object",
          "properties" => %{
            "subscribe" => %{"type" => "boolean"},
            "listChanged" => %{"type" => "boolean"}
          }
        },
        "tools" => %{
          "type" => "object",
          "properties" => %{
            "listChanged" => %{"type" => "boolean"}
          }
        }
      },
      "additionalProperties" => true
    }
  end

  def text_content("2024-11-05") do
    %{
      "type" => "object",
      "required" => ["type", "text"],
      "properties" => %{
        "type" => %{"enum" => ["text"]},
        "text" => %{"type" => "string"}
      },
      "additionalProperties" => true
    }
  end

  def image_content("2024-11-05") do
    %{
      "type" => "object",
      "required" => ["type", "data", "mimeType"],
      "properties" => %{
        "type" => %{"enum" => ["image"]},
        "data" => %{"type" => "string", "format" => "base64"},
        "mimeType" => %{"type" => "string"}
      },
      "additionalProperties" => true
    }
  end

  def resource_contents("2024-11-05") do
    %{
      "type" => "object",
      "required" => ["uri"],
      "properties" => %{
        "uri" => %{"type" => "string"},
        "mimeType" => %{"type" => "string"}
      },
      "additionalProperties" => true
    }
  end

  def prompt_message("2024-11-05") do
    %{
      "type" => "object",
      "required" => ["role", "content"],
      "properties" => %{
        "role" => %{"enum" => ["user", "assistant"]},
        "content" => %{
          "oneOf" => [
            text_content("2024-11-05"),
            image_content("2024-11-05")
          ]
        }
      },
      "additionalProperties" => true
    }
  end

  def tool("2024-11-05") do
    %{
      "type" => "object",
      "required" => ["name", "inputSchema"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "inputSchema" => %{
          "type" => "object",
          "required" => ["type"],
          "properties" => %{
            "type" => %{"enum" => ["object"]},
            "properties" => %{"type" => "object"}
          },
          "additionalProperties" => true
        }
      },
      "additionalProperties" => true
    }
  end
end
