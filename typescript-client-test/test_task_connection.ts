// Use the local compiled SDK with enhanced logging
import { Client } from "./typescript-sdk/src/client/index.js";
import { SSEClientTransport } from "./typescript-sdk/src/client/sse.js";
import { z } from "zod";

// --- Configuration ---
// Read port from environment variable set by the Mix task, default to 4001 for task server
const port = process.env.MCP_TASK_SERVER_PORT ? parseInt(process.env.MCP_TASK_SERVER_PORT, 10) : 4001;
const serverUrl = `http://localhost:${port}/task/sse`; // Construct URL dynamically for task server
const clientInfo = { name: "mcp-task-test-client", version: "0.0.1" };
// ---

async function runTaskTest() {
	console.log(`\nAttempting full MCP connection to ${serverUrl} via SSE (Task Server)...`);

	// Use default transport options (including fetch wrapper)
	const transport = new SSEClientTransport(new URL(serverUrl));
	// Configure client with Zod error reporting enabled
	const client = new Client(clientInfo, { 
		capabilities: {}, 
		// Enable Zod errors to be propagated with full details
		zodErrorReporting: true 
	});

	transport.onmessage = (message: any) => {
		console.log("[TS Task Client - Transport] Raw Message Received:", message);
	};

	transport.onerror = (error: any) => {
		console.error("[TS Task Client - Transport] Error:", error);
	};

	transport.onclose = () => {
		console.log("[TS Task Client - Transport] Connection Closed");
	};

	try {
		// Use the standard client.connect() again
		console.log("[TS Task Client] Initiating client.connect()...");
		await client.connect(transport); // This should now work with the server fix
		console.log("[TS Task Client] ✅ client.connect() successful!");
		console.log("[TS Task Client] Server Info:", client.getServerVersion());
		console.log("[TS Task Client] Server Capabilities:", client.getServerCapabilities());

		// Add a small delay to allow server state to potentially update
		console.log("[TS Task Client] Waiting 100ms before listing tools...");
		await new Promise(resolve => setTimeout(resolve, 100)); 

		try {
			console.log("[TS Task Client] Attempting client.listTools() with 15s timeout...");
			const toolsResult = await client.listTools(undefined, { timeout: 15000 }); // Use 15s timeout
			console.log("[TS Task Client] ✅ client.listTools() successful!");
			console.log("[TS Task Client] Tools:", JSON.stringify(toolsResult.tools, null, 2));

			if (toolsResult.tools && toolsResult.tools.length > 0) {
				const echoTool = toolsResult.tools.find((tool: any) => tool.name === 'echo');
				if (echoTool) {
					console.log("[TS Task Client] Attempting to call echo tool...");
					const callResult = await client.callTool({
						name: "echo",
						arguments: { message: "Hello from TypeScript task client!" }
					});
					console.log("[TS Task Client] ✅ Tool call successful!");
					console.log("[TS Task Client] Result:", JSON.stringify(callResult, null, 2));
				}
			}
		} catch (listToolsError) {
			console.error("[TS Task Client] ❌ Error during client.listTools():", listToolsError);
			if (listToolsError instanceof z.ZodError) {
				console.error("[TS Task Client] Zod validation errors:", JSON.stringify(listToolsError.format(), null, 2));
			}
		}

	} catch (connectError) {
		console.error("[TS Task Client] ❌ Error during client.connect():", connectError);
		if (connectError instanceof z.ZodError) {
			console.error("[TS Task Client] Zod validation errors:", JSON.stringify(connectError.format(), null, 2));
		}
		process.exit(1); // Exit with error code if connect fails
	} finally {
		console.log("[TS Task Client] Closing client connection...");
		await client.close();
		console.log("[TS Task Client] Client connection closed.");
	}
}

console.log("[TS Task Client] Starting task test run...");
runTaskTest().catch(err => {
	console.error("[TS Task Client] Unhandled error during task test run:", err);
	if (err instanceof z.ZodError) {
		console.error("[TS Task Client] Zod validation errors:", JSON.stringify(err.format(), null, 2));
	}
	process.exit(1);
}); 