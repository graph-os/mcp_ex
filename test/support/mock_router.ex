defmodule Mcp.Test.MockRouter do
  @moduledoc """
  A minimal Plug router for use in integration tests where a simple
  HTTP server is needed, but not the full MCP endpoint.
  """
  use Plug.Router

  plug :match
  plug :dispatch

  # A simple health check or readiness probe endpoint
  get "/_health" do
    send_resp(conn, 200, "OK")
  end

  # Catch-all for any other request
  match _ do
    send_resp(conn, 404, "Not Found by MockRouter")
  end
end
