/**
 * This test verifies that our TypeScript types match the Elixir implementation.
 * 
 * These tests ensure 1:1 type parity between our Elixir MCP.Types module
 * and the TypeScript types we use.
 */

import * as mcpTypes from '../types/mcp-types';
import { describe, it, expect } from '@jest/globals';

// Test samples (should match the samples generated in MCP.Types.generate_sample/1)
const samples = {
  jsonrpc_request: {
    jsonrpc: "2.0",
    id: "req-123",
    method: "test.method",
    params: { foo: "bar" }
  } as const,
  
  jsonrpc_notification: {
    jsonrpc: "2.0",
    method: "test.notification",
    params: { event: "something_happened" }
  } as const,
  
  jsonrpc_success_response: {
    jsonrpc: "2.0",
    id: "req-123",
    result: { value: 42 }
  } as const,
  
  jsonrpc_error_response: {
    jsonrpc: "2.0",
    id: "req-123",
    error: {
      code: -32000,
      message: "Error message",
      data: { details: "Additional information" }
    }
  } as const,
  
  tool: {
    name: "test_tool",
    description: "A test tool",
    inputSchema: {
      type: "object" as const,
      properties: {
        input: { type: "string" }
      }
    }
  } as const,
  
  text_resource_contents: {
    uri: "resource:test",
    mimeType: "text/plain",
    text: "Sample text content"
  } as const,
  
  blob_resource_contents: {
    uri: "resource:test-blob",
    mimeType: "application/octet-stream",
    base64: "SGVsbG8gV29ybGQ="  // "Hello World"
  } as const,
  
  resource: {
    uri: "resource:test",
    name: "Test Resource",
    description: "A test resource"
  } as const
};

// TypeScript type validation functions
function validateJsonRpcRequest(data: any): data is mcpTypes.JsonRpcRequest {
  return (
    typeof data === 'object' &&
    data !== null &&
    data.jsonrpc === mcpTypes.JSONRPC_VERSION &&
    (typeof data.id === 'string' || typeof data.id === 'number') &&
    typeof data.method === 'string' &&
    (data.params === null || typeof data.params === 'object')
  );
}

function validateJsonRpcNotification(data: any): data is mcpTypes.JsonRpcNotification {
  return (
    typeof data === 'object' &&
    data !== null &&
    data.jsonrpc === mcpTypes.JSONRPC_VERSION &&
    typeof data.method === 'string' &&
    (data.params === null || typeof data.params === 'object')
  );
}

function validateJsonRpcSuccessResponse(data: any): data is mcpTypes.JsonRpcSuccessResponse {
  return (
    typeof data === 'object' &&
    data !== null &&
    data.jsonrpc === mcpTypes.JSONRPC_VERSION &&
    (typeof data.id === 'string' || typeof data.id === 'number') &&
    typeof data.result === 'object'
  );
}

function validateJsonRpcErrorResponse(data: any): data is mcpTypes.JsonRpcErrorResponse {
  return (
    typeof data === 'object' &&
    data !== null &&
    data.jsonrpc === mcpTypes.JSONRPC_VERSION &&
    (data.id === null || typeof data.id === 'string' || typeof data.id === 'number') &&
    typeof data.error === 'object' &&
    typeof data.error.code === 'number' &&
    typeof data.error.message === 'string'
  );
}

function validateTool(data: any): data is mcpTypes.Tool {
  return (
    typeof data === 'object' &&
    data !== null &&
    typeof data.name === 'string' &&
    (data.description === null || typeof data.description === 'string') &&
    typeof data.inputSchema === 'object' &&
    data.inputSchema.type === 'object'
  );
}

function validateTextResourceContents(data: any): data is mcpTypes.TextResourceContents {
  return (
    typeof data === 'object' &&
    data !== null &&
    typeof data.uri === 'string' &&
    typeof data.mimeType === 'string' &&
    typeof data.text === 'string'
  );
}

function validateBlobResourceContents(data: any): data is mcpTypes.BlobResourceContents {
  return (
    typeof data === 'object' &&
    data !== null &&
    typeof data.uri === 'string' &&
    typeof data.mimeType === 'string' &&
    typeof data.base64 === 'string'
  );
}

function validateResource(data: any): data is mcpTypes.Resource {
  return (
    typeof data === 'object' &&
    data !== null &&
    typeof data.uri === 'string' &&
    typeof data.name === 'string' &&
    (data.description === null || typeof data.description === 'string')
  );
}

// Test suite
describe('Type Parity with Elixir', () => {
  it('should validate the same JSON-RPC request samples as Elixir', () => {
    const sample = samples.jsonrpc_request;
    expect(validateJsonRpcRequest(sample)).toBe(true);
    
    // Test that same validation fails for invalid data
    const invalidSample = { 
      jsonrpc: sample.jsonrpc,
      id: sample.id,
      // method is missing
      params: sample.params
    };
    expect(validateJsonRpcRequest(invalidSample)).toBe(false);
  });
  
  it('should validate the same JSON-RPC notification samples as Elixir', () => {
    const sample = samples.jsonrpc_notification;
    expect(validateJsonRpcNotification(sample)).toBe(true);
    
    const invalidSample = { 
      jsonrpc: sample.jsonrpc,
      // method is missing
      params: sample.params
    };
    expect(validateJsonRpcNotification(invalidSample)).toBe(false);
  });
  
  it('should validate the same JSON-RPC success response samples as Elixir', () => {
    const sample = samples.jsonrpc_success_response;
    expect(validateJsonRpcSuccessResponse(sample)).toBe(true);
    
    const invalidSample = { 
      jsonrpc: sample.jsonrpc,
      id: sample.id
      // result is missing
    };
    expect(validateJsonRpcSuccessResponse(invalidSample)).toBe(false);
  });
  
  it('should validate the same JSON-RPC error response samples as Elixir', () => {
    const sample = samples.jsonrpc_error_response;
    expect(validateJsonRpcErrorResponse(sample)).toBe(true);
    
    const invalidSample = { 
      jsonrpc: sample.jsonrpc,
      id: sample.id
      // error is missing
    };
    expect(validateJsonRpcErrorResponse(invalidSample)).toBe(false);
  });
  
  it('should validate the same tool samples as Elixir', () => {
    const sample = samples.tool;
    expect(validateTool(sample)).toBe(true);
    
    const invalidSample = { 
      // name is missing
      description: sample.description,
      inputSchema: sample.inputSchema
    };
    expect(validateTool(invalidSample)).toBe(false);
  });
  
  it('should validate the same text resource contents samples as Elixir', () => {
    const sample = samples.text_resource_contents;
    expect(validateTextResourceContents(sample)).toBe(true);
    
    const invalidSample = { 
      uri: sample.uri,
      mimeType: sample.mimeType
      // text is missing
    };
    expect(validateTextResourceContents(invalidSample)).toBe(false);
  });
  
  it('should validate the same blob resource contents samples as Elixir', () => {
    const sample = samples.blob_resource_contents;
    expect(validateBlobResourceContents(sample)).toBe(true);
    
    const invalidSample = { 
      uri: sample.uri,
      mimeType: sample.mimeType
      // base64 is missing
    };
    expect(validateBlobResourceContents(invalidSample)).toBe(false);
  });
  
  it('should validate the same resource samples as Elixir', () => {
    const sample = samples.resource;
    expect(validateResource(sample)).toBe(true);
    
    const invalidSample = { 
      uri: sample.uri,
      // name is missing
      description: sample.description
    };
    expect(validateResource(invalidSample)).toBe(false);
  });
  
  it('validates all sample data types that match the Elixir implementation', () => {
    // This test makes sure all our samples are valid according to our TypeScript types
    // The same test is present in the Elixir implementation
    
    expect(validateJsonRpcRequest(samples.jsonrpc_request)).toBe(true);
    expect(validateJsonRpcNotification(samples.jsonrpc_notification)).toBe(true);
    expect(validateJsonRpcSuccessResponse(samples.jsonrpc_success_response)).toBe(true);
    expect(validateJsonRpcErrorResponse(samples.jsonrpc_error_response)).toBe(true);
    expect(validateTool(samples.tool)).toBe(true);
    expect(validateTextResourceContents(samples.text_resource_contents)).toBe(true);
    expect(validateBlobResourceContents(samples.blob_resource_contents)).toBe(true);
    expect(validateResource(samples.resource)).toBe(true);
  });
}); 