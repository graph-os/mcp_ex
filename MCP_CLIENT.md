# MCP Connection Debugging Report (Elixir Server vs. Cline Client)

## Problem

The Cline VS Code extension (acting as an MCP client) successfully initiates an SSE connection to the local Elixir MCP server (`graph_os_protocol`), but gets stuck displaying "Restarting..." or "Connecting..." and never shows the available tools. Server logs indicate the `initialize` handshake completes successfully, but subsequent requests like `tools/list` are never received from the client.

## Investigation Summary

We performed extensive debugging on both the server and client sides (using reference code).

**Server-Side (Elixir - `mcp` & `graph_os_protocol`):**

1.  **Protocol Version:** Confirmed the server uses MCP protocol version `2024-11-05` (defined in `mcp/lib/mcp/message.ex`).
2.  **Transport:** Uses Bandit adapter with default settings (HTTP/1.1) on `http://localhost:4000`. Explicitly binding to `127.0.0.1` vs `0.0.0.0` made no difference to the core issue. HTTP/2 is not required for SSE.
3.  **SSE Handshake:**
    *   Correctly handles the initial `GET /` request from the client.
    *   Establishes the SSE stream (`text/event-stream`, `keep-alive`).
    *   Generates a session ID and registers the connection process.
    *   **Crucially, sends the `endpoint` event back to the client immediately after connection** (`event: endpoint\ndata: /?sessionId=...\n\n`). This was identified as a missing step and fixed.
4.  **Initialize Request Handling:**
    *   Correctly receives the `POST /?sessionId=...` request for the `initialize` method.
    *   Parses the request body using `Plug.Parsers`.
    *   Calls the `GraphOS.Protocol.MCPImplementation.handle_initialize` callback (which uses the default `MCP.Server` implementation).
    *   Updates the session state in the `ConnectionRegistry` to mark it as `initialized: true`.
    *   Sends a successful `InitializeResult` back to the client with a 200 OK status, echoing the request ID (tested with both `0` and a fixed `999`). The response includes the correct protocol version and server info.
5.  **`initialized` Notification Handling:** The server uses the default notification handler from `MCP.Server`, which correctly ignores the `notifications/initialized` message sent by the client after successful initialization (this notification was confirmed to be received in server logs during earlier debugging steps before logs were removed).
6.  **`tools/list` Handler:** The `handle_list_tools` implementation was corrected to remove the non-standard `outputSchema` key, ensuring the response strictly adheres to the expected schema.
7.  **Debugging Steps:** Added extensive logging, tested different response IDs, added artificial delays – none resolved the client-side issue.

**Client-Side (Cline Extension / TypeScript SDK - via `reference/` code):**

1.  **Protocol Version:** The reference TypeScript SDK (`reference/typescript-sdk/src/types.ts`) also targets `2024-11-05` as the latest version.
2.  **Connection Flow (`McpHub.ts` & SDK):**
    *   `McpHub.ts` creates an `SSEClientTransport` and a `Client`.
    *   It calls `await client.connect(transport)`.
    *   The SDK's `Client.connect` method first establishes the transport connection (GET request, waits for `endpoint` event) and *then* sends the `initialize` request using `client.request()`.
    *   After `client.connect()` resolves, `McpHub.ts` calls `fetchToolsList()`, which uses `client.request({ method: "tools/list" }, ...)`.
3.  **Observed Behavior:**
    *   The client successfully performs the initial GET and sends the `initialize` POST.
    *   The client *receives* the successful `InitializeResult` from the server (implied, as the server logs sending it and no network errors occur at this stage).
    *   The client then **times out** during the `client.connect()` process, logging `McpError: MCP error -32001: Request timed out`.
    *   The `client.connect()` promise rejects due to the timeout.
    *   As a result, `McpHub.ts` never reaches the `fetchToolsList()` call.
4.  **Timeout Error:**
    *   The error code `-32001` corresponds to `ErrorCode.RequestTimeout` as defined in the reference TypeScript SDK (`src/types.ts`).
    *   The error message "Request timed out" also matches the SDK's timeout error.
    *   The timeout occurs despite the server responding quickly to the `initialize` request.
5.  **Test Script:** A standalone Node.js test script using the SDK showed initial connectivity issues (`ECONNREFUSED`) likely due to server binding, but after fixing that, it also appeared to hang during the `client.connect()` phase, similar to the Cline extension.

## Conclusion

The Elixir server implementation appears to correctly follow the MCP specification for the SSE transport and initialization handshake. It successfully receives the `initialize` request and sends a valid success response.

The issue lies on the **client side**, specifically within the TypeScript SDK's `Client.connect` method or its interaction with the `SSEClientTransport`. The client times out *after* the server has successfully responded to the `initialize` request. This likely happens either:

1.  During the client's internal processing of the received `InitializeResult`.
2.  During the client's attempt to send the subsequent `notifications/initialized` message back to the server.

A subtle bug, race condition, or unexpected blocking behavior within the client SDK or the Cline extension's usage of it seems to be preventing the `connect` method from resolving successfully, thus preventing the subsequent `tools/list` request and causing the UI to remain stuck. Further investigation requires debugging the client-side TypeScript code.

## Update (2025-04-04)

Further debugging revealed several server-side issues that were corrected:
1.  **Conflicting Routers:** Removed duplicate `/sse` handling in `GraphOS.Protocol.Router`.
2.  **Plug Usage:** Ensured `GraphOS.Protocol.Router` forwards `/sse` and `/rpc/:session_id` to `SSE.ConnectionPlug`.
3.  **SSE Plug Logic:** Corrected `SSE.ConnectionPlug` to:
    *   Generate `session_id` on initial `GET /sse`.
    *   Send the correct `/rpc/:session_id` endpoint event.
    *   Correctly handle `POST /rpc/:session_id` requests by extracting `session_id` from path parameters.
    *   Use `Plug.Parsers` correctly.
4.  **MCP Server Logic:**
    *   Removed an incorrect standalone `handle_message/2` function that was overriding the default implementation and causing "Unknown message type" errors.
    *   Fixed minor logging/pattern matching errors in the ping loop.
5.  **Application Startup:** Ensured `SSE.ConnectionRegistry` is started correctly by the `:mcp` application dependency.

**Update (2025-04-04 Evening):**

Further debugging and fixes:
1.  **Server Dispatch Logic:** Corrected `SSE.ConnectionHandler` to use a new public `MCP.Server.dispatch_request/4` function, ensuring proper delegation to the implementation module (`GraphOS.Protocol.MCPImplementation`) instead of incorrectly calling the behaviour module directly. This resolved the `UndefinedFunctionError` for `MCP.Server.handle_message/2`.
2.  **Configuration:** Added the required `:implementation_module` configuration to both `config/test.exs` and `config/dev.exs`.
3.  **Elixir Tests:**
    *   Removed problematic `meck` usage from `sse_router_test.exs`.
    *   Enhanced `sse_client_simulation_test.exs` to keep the SSE socket open and assert the reception and structure of the `InitializeResult` event over the stream.
    *   Enhanced `sse_connection_setup_test.exs` to assert the reception of the `endpoint` event.
    *   The Elixir tests now pass, confirming the server sends the `InitializeResult` correctly over the SSE stream.
4.  **TypeScript Client Test (`test_connection.ts`):**
    *   Copied SDK source locally (`mcp_client_test/sdk-src`) and updated imports.
    *   Added logging to the SDK's `SSEClientTransport` (`sse.ts`).
    *   Initial runs with the fixed server dispatch showed the client still failing, but logs revealed a `ZodError` during parsing of the received `InitializeResult`. The schema expected `result._meta` and `result.instructions` to be objects or strings, but the server was sending `null`.
    *   Modified the Elixir server (`MCP.Server.dispatch_request`) to explicitly omit `_meta` and `instructions` from the encoded `InitializeResult` map if they are `nil`.
    *   Fixed syntax errors introduced during previous edits.
    *   **Current Issue:** The `mix protocol.server stop/restart` commands started failing with a recursive configuration loading error after editing `config/dev.exs`. The server had to be started manually for the last client test run.

**Current Status:**
- Elixir server correctly sends `endpoint` event and `InitializeResult` event over the SSE stream (confirmed by Elixir tests and server logs).
- TypeScript client (`test_connection.ts`) successfully connects (`client.connect()` resolves) after server fixes for `_meta` and `instructions` fields.
- **New Failure:** The TS client now fails during the subsequent `client.listTools()` call, receiving a "Session not initialized" error from the server. Server logs also show a malformed error message (`id: null`) being received by the client just before the valid error.

**Revised Hypothesis:**
The primary connection issue seems resolved. The new "Session not initialized" error suggests a potential race condition or timing issue on the server side. The server might be processing the `listTools` request (sent immediately after `connect()` resolves) before the session state associated with the `initialize` request is fully updated or persisted in the `ConnectionRegistry`. The malformed `id: null` error message received by the client needs further investigation.

**Next Steps:**
1. Investigate the "Session not initialized" error. This likely involves checking the timing of the `ConnectionRegistry.update_data` call within `MCP.Server.dispatch_request` relative to when subsequent requests might arrive and be processed by `SSE.ConnectionHandler`. Ensure the `initialized: true` flag is reliably set and readable before processing further requests for that session.
2. Investigate the source of the malformed error message (`id: null`) seen in the client logs. (Resolved by fixing error handling paths).
3. Resolve the recursive configuration loading error affecting `mix protocol.server stop/restart`. (Resolved by making `:mcp` config conditional, then reverting as it wasn't needed for `mix run`).

**Update (2025-04-04 Late Evening):**

After extensive refactoring involving registry keys (`session_id` vs `handler_pid`), fixing GenServer vs Module usage for the registry, correcting logger calls, and ensuring correct application startup order and configuration loading:

- **Current Status:**
    - The `mix protocol.server restart` command now works reliably.
    - The TypeScript client (`test_connection.ts`) **successfully connects** (`client.connect()` resolves). The `initialize` handshake completes without error.
    - **New Failure:** The client **times out** when calling `client.listTools()` immediately after a successful connection. The server receives the request but does not appear to send a response, causing the client-side timeout.

- **Revised Hypothesis:**
    - The core connection and initialization issues are resolved.
    - The `tools/list` timeout suggests a potential issue in the server-side processing or response path for this specific method *after* initialization. This could be within:
        - `GraphOS.Protocol.MCPImplementation.handle_list_tools` (though it looks simple).
        - `MCP.Dispatcher.dispatch_method` when formatting the `tools/list` response.
        - The `SSE.ConnectionHandler` or `SSE.ConnectionPlug` when sending the response chunk back to the client.

- **Simplification Recommendations:**
    - The current interaction between `SSE.ConnectionPlug`, `SSE.ConnectionHandler`, `SSE.ConnectionRegistry`, and `MCP.Dispatcher` (handling message dispatch and state) is complex and was the source of several bugs.
    - **Consider consolidating state:** Move session state (like `initialized`, `client_info`) entirely into the `SSE.ConnectionHandler`'s state instead of splitting it with the `ConnectionRegistry` metadata. The registry could then simply map `session_id` to `handler_pid`.
    - **Consider simplifying dispatch:** The `SSE.ConnectionHandler` could potentially call the `GraphOS.Protocol.MCPImplementation` functions directly after fetching state, bypassing the `MCP.Dispatcher` layer for message routing, reducing indirection.

- **Next Steps:**
    1. Investigate the `tools/list` timeout. Use `dbg()` in `MCP.Dispatcher.dispatch_method` (tools/list case) and `GraphOS.Protocol.MCPImplementation.handle_list_tools` to trace execution and return values.
    2. If the implementation returns correctly, trace the response path through `SSE.ConnectionHandler` and `SSE.ConnectionPlug` using `dbg()` to see where the response message might be getting lost or delayed.
    3. Consider implementing the simplification recommendations above if debugging the current flow proves difficult.

## Update (2025-04-05)

Enhanced client-side logging reveals several key issues in the interaction between the TypeScript client and Elixir server:

1. **Connection and Initialization**:
   - The SSE connection and `initialize` handshake complete successfully
   - Server sends a correct `InitializeResult` response
   - Client successfully parses the response and resolves the `client.connect()` promise

2. **Notifications Handling Issue**:
   - After successful initialization, the client sends a `notifications/initialized` notification
   - Server responds with an error: `Method not found: notifications/initialized` with `id: null`
   - Client receives this error message but fails to parse it due to ZodSchema validation errors
   - This error does not affect connection establishment since the client doesn't await notification responses

3. **Response Message Handling Issues**:
   - The client successfully sends the `tools/list` request and the server processes it
   - Server logs show it successfully constructs and sends a response with tools data
   - The client receives this response over the SSE stream
   - Client fails to parse the response due to another ZodSchema validation error
   - Since the message cannot be parsed, the client's request promise never resolves
   - This leads to the 120-second timeout we observed in testing

4. **Root Causes**:
   - Server is correctly sending responses through the SSE stream
   - Client schema validation is failing for both the error response and tool list response
   - The invalid responses still appear in client logs but are not passed to the response handlers
   - Error messages indicate mismatch between expected message structure and actual server responses

The fundamental issue appears to be related to how the server sends messages over the SSE stream and how they are validated by the client. The client expects a specific structure for each message type, and the validation is failing for responses. The response path is correct but validation prevents normal processing.

Testing with a modified client with enhanced debugging confirms: 
1. Messages are flowing in both directions
2. The server is processing requests correctly
3. Schema validation is preventing proper response handling on the client side

**Next Steps**:
1. Examine message structure/schema differences between client expectations and server outputs
2. Update either the client schema validation or server response format to match
3. Consider relaxing schema validation during development for easier debugging
4. Implement proper standardized notification handling on the server side
