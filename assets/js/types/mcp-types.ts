/**
 * Minimal MCP type definitions.
 * These match the types in the MCP.Types Elixir module.
 */

// Protocol constants
export const LATEST_PROTOCOL_VERSION = "2024-11-05";
export const JSONRPC_VERSION = "2.0";

// Basic types
export type ProgressToken = string | number;
export type Cursor = string;
export type RequestId = string | number;

// JSON-RPC types
export interface JsonRpcRequest {
  jsonrpc: string;
  id: RequestId;
  method: string;
  params?: Record<string, any> | null;
}

export interface JsonRpcNotification {
  jsonrpc: string;
  method: string;
  params?: Record<string, any> | null;
}

export interface JsonRpcSuccessResponse {
  jsonrpc: string;
  id: RequestId;
  result: Record<string, any>;
}

export interface JsonRpcErrorResponse {
  jsonrpc: string;
  id?: RequestId | null;
  error: {
    code: number;
    message: string;
    data?: any;
  };
}

export type JsonRpcResponse = JsonRpcSuccessResponse | JsonRpcErrorResponse;
export type JsonRpcMessage = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;

// Tool types
export interface Tool {
  name: string;
  description?: string | null;
  inputSchema: {
    type: "object";
    properties?: Record<string, any> | null;
  };
}

export interface CallToolResult {
  _meta?: Record<string, any> | null;
  result: any;
}

// Resource types
export interface TextResourceContents {
  uri: string;
  mimeType: string;
  text: string;
}

export interface BlobResourceContents {
  uri: string;
  mimeType: string;
  base64: string;
}

export type ResourceContents = TextResourceContents | BlobResourceContents;

export interface Resource {
  uri: string;
  name: string;
  description?: string | null;
} 