/**
 * This file exports MCP type definitions.
 * These types match the Elixir implementation in MCP.Types.
 */

// Export all our local type definitions
export * from './mcp-types';

// MCP version management
export interface ServerCapabilities {
  supportedVersions: string[];
}

export interface ServerInfo {
  name: string;
  version: string;
}

export interface InitializeResult {
  protocolVersion: string;
  serverInfo: ServerInfo;
  capabilities: ServerCapabilities;
}

// Error codes for MCP protocol
export const ErrorCodes = {
  // JSON-RPC standard error codes
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,

  // MCP-specific error codes
  NotInitialized: -32000,
  ProtocolVersionMismatch: -32001,
  ToolNotFound: -32002
};

// Add any additional type definitions specific to your Elixir implementation below
// export interface ElixirSpecificType { ... } 