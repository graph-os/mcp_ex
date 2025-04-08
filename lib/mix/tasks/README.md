# Mix Tasks for MCP Server

This directory contains Mix tasks for the Model Context Protocol (MCP) server component.

These tasks provide convenient ways to start the MCP server in different modes
for development, debugging, and testing.

## Available Tasks

* `mix mcp.sse`: Starts the server in standard SSE mode.
* `mix mcp.debug`: Starts the server in debug mode (JSON API only).
* `mix mcp.inspect`: Starts the server with the full HTML/JS inspector UI.
* `mix mcp.stdio`: Provides a STDIO interface for the server (e.g., for Windsurf).
* `mix mcp.test_client`: Runs a Python test client against the server.
