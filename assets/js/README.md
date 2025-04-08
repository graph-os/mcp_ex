# MCP TypeScript Testing Tools

This directory contains the TypeScript SDK for the Model Context Protocol (MCP), used for testing the Elixir implementation.

## Structure

- `node_modules/@modelcontextprotocol/sdk`: The MCP TypeScript SDK (installed via npm)
- `extracted-types/`: Extracted type definitions from the SDK for reference
- `types/`: Symbolic links to the original type definitions
- `scripts/`: Utility scripts for working with the SDK

## Key Files

- `extracted-types/index.ts`: Overview of all MCP types 
- `extracted-types/constants.ts`: Protocol constants
- `extracted-types/schemas.ts`: Zod schema definitions
- `scripts/extract-types.js`: Script to extract types from the SDK

## Type Reference for Elixir Implementation

The Elixir types in `apps/mcp/lib/mcp/types.ex` are based on the TypeScript SDK types. Use the extracted types in `extracted-types/` as a reference when implementing the protocol in Elixir.

## Using the SDK for Testing

```typescript
import { Client } from "@modelcontextprotocol/sdk/client";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse";

// Connect to the Elixir MCP server
const transport = new SSEClientTransport({
  baseUrl: "http://localhost:4000/mcp",
});

const client = new Client({
  name: "test-client",
  version: "1.0.0",
});

await client.connect(transport);

// Test server capabilities
const capabilities = await client.request(
  { method: "initialize" },
  InitializeResultSchema
);

// List available tools
const tools = await client.request(
  { method: "tools/list" },
  ListToolsResultSchema
);

// Call a tool
const result = await client.request(
  { 
    method: "tools/call", 
    params: { 
      name: "example-tool",
      arguments: { /* tool parameters */ }
    }
  },
  CallToolResultSchema
);
```

## Regenerating Type Definitions

If the SDK is updated, run the extraction script to update the type references:

```bash
node scripts/extract-types.js
``` 