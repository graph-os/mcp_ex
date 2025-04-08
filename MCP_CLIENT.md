# MCP Connection Debugging Report (Elixir Server vs. Clients)

## SSE Connection (Cline Client)

*Initial Problem:* Cline client connected via SSE but timed out or failed during/after initialization, preventing tool listing.

*Resolution:* Multiple server-side fixes were implemented (SSE endpoint event, dispatcher logic, registry handling, message schemas for InitializeResult). The SSE connection via `test_connection.ts` now successfully initializes, but subsequent `tools/list` calls were timing out (later resolved).

## Stdio Connection (TypeScript Test Client)

*Goal:* Establish a direct stdio connection between the TypeScript test client (`test_stdio_connection.ts`) and the Elixir MCP implementation, bypassing HTTP/SSE.

*Problem:* Persistent failure to establish a connection. The client typically fails either immediately ("Connection closed") or after a timeout ("Request timed out"). Investigation revealed that the stdio channel used for MCP communication was being contaminated by extraneous output from the Elixir process *before* the MCP framing/message handling could reliably take over.

*Attempted Solutions & Findings:*

1.  **Mix Task (`mix mcp.stdio --direct`):** Initial attempts used a Mix task. This failed because Mix's own compilation messages and application startup logs (e.g., `[info] Starting...`) were written to stdout, confusing the client's message parser.
2.  **Silencing Mix (`mix run -e`, `--no-compile`):** Tried various `mix run` flags (`-e`, `--no-compile`, `--no-deps-check`) to suppress Mix output, but application startup messages still leaked to stdout.
3.  **Early Logger Config:** Configuring `Logger` to remove the `:console` backend at the very beginning of the Mix task or application start helped, but *some* initial OTP/supervisor messages were still emitted to stdout before the configuration took effect.
4.  **Dedicated Script (`elixir script.exs`):** Running a plain `.exs` script using `elixir -pa <paths> -S script.exs` failed, likely due to an incomplete application environment compared to `mix run`.
5.  **Elixir Release (`_build/.../bin/mcp`):**
    *   *Custom Command (`bin/mcp stdio`):* A release was built with a custom command. This failed immediately ("Connection closed"), suggesting the command didn't correctly start the OTP application/supervision tree before running the stdio server code, leading to errors (e.g., `ConnectionRegistryServer` not running).
    *   *Environment Variable (`MCP_MODE=stdio bin/mcp start`):* The application was modified to check `MCP_MODE` and start different children. This successfully started the stdio server logic *but* still suffered from initial OTP application startup messages (`[info] Starting...`) polluting stdout before the logger backend could be removed.

*Root Cause Summary:* The Elixir OTP application startup process inherently logs informational messages to the process's standard output via the default `:console` logger backend. It's difficult to prevent this initial output completely from within the application code or standard release startup scripts, as it happens before custom logger configuration can reliably take effect. This contaminates the stdio channel expected by the MCP client.

*Potential Paths Forward for Stdio:*

1.  **Elixir Release (Refined):** (Recommended, Standard) Investigate advanced release configuration (`vm.args`, `env.sh`, boot scripts) to redirect or silence the *initial* BEAM/OTP stdout noise *before* the `mcp` application starts. This requires deeper Elixir/OTP release knowledge but is the most standard approach.
2.  **Erlang Port:** (Complex, Robust) Implement the stdio logic in a separate program (e.g., an `escript`) managed as an Erlang Port by the main Elixir application. Communication between the main app and the port uses a clean stdio channel provided by OTP.
3.  **Client-Side Filtering:** (Not Feasible) Modify the *client* transport to intelligently filter out non-MCP messages. This is not an option as we cannot modify the third-party client SDK.
4.  **Alternative Transport:** (Workaround) Use a different transport like WebSockets for testing the core MCP logic if *stdio transport specifically* is not the primary focus of the test.

*Current Recommendation:* Pursue the **Elixir Release (Refined)** path (1) by investigating OTP/release mechanisms for controlling initial boot-time stdout. If that proves too difficult or time-consuming, consider the **Erlang Port** architecture (2).
