// Test for stdio connection using the mix_task_runner server
import { Client } from "./typescript-sdk/src/client/index";
import { StdioClientTransport, StdioServerParameters } from "./typescript-sdk/src/client/stdio";
import { z } from "zod";
import path from "path";
import { fileURLToPath } from 'url';

// --- Configuration ---
const clientInfo = { name: "mcp-test-client-stdio", version: "0.0.1" };
// Get the directory of the current module
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
// Construct the path to the Elixir project root relative to this test file
const projectRoot = path.resolve(__dirname, '../'); // Go up one level

// Configuration for spawning the Elixir stdio server
const serverParams: StdioServerParameters = {
	// Execute the release binary directly
	command: "_build/dev/rel/mcp/bin/mcp", 
	// Use the default 'start' command, mode is controlled by env var
	args: ["start"], 
	// Set environment variable to trigger stdio mode in Application.start/2
	env: { ...process.env, "MCP_MODE": "stdio" }, 
	cwd: projectRoot, 
	stderr: "pipe", 
};
// ---

async function runTest() {
	console.log(`\nAttempting full MCP connection via Stdio...`);
	console.log(`Spawning server with: MCP_MODE=stdio ${serverParams.command} ${(serverParams.args ?? []).join(' ')} in ${serverParams.cwd}`);

	// Use Stdio transport with server parameters
	const transport = new StdioClientTransport(serverParams); // Pass serverParams

	// --- BEGIN ADDED LOGGING FOR STDERR --- 
	// Capture and log stderr from the spawned Elixir process
	let stderrOutput = '';
	transport.stderr?.on('data', (data) => {
		const str = data.toString();
		stderrOutput += str;
		console.error(`[Mix Task STDERR]: ${str}`); 
	});
	transport.stderr?.on('end', () => {
		if (stderrOutput.length > 0) {
			console.error('[Mix Task STDERR] Closed.');
		}
	});
	// --- END ADDED LOGGING FOR STDERR --- 

	// Configure client
	const client = new Client(clientInfo, {
		capabilities: {},
	});

	transport.onmessage = (message) => {
		// Stdio transport should parse JSONRPC messages
		console.log("[TS Client - Stdio Transport] Message Received:", JSON.stringify(message, null, 2));
	};

	transport.onerror = (error) => {
		console.error("[TS Client - Stdio Transport] Error:", error);
	};

	transport.onclose = () => {
		console.log("[TS Client - Stdio Transport] Connection Closed");
	};

	try {
		// Use the standard client.connect()
		console.log("[TS Client] Initiating client.connect() via Stdio...");
		// Connect will internally call transport.start()
		await client.connect(transport);
		console.log("[TS Client] ✅ client.connect() successful!");
		console.log("[TS Client] Server Info:", client.getServerVersion()); // May be undefined for stdio
		console.log("[TS Client] Server Capabilities:", client.getServerCapabilities()); // May be undefined for stdio

		// Add a small delay to allow server state to potentially update
		console.log("[TS Client] Waiting 100ms before listing tools...");
		await new Promise(resolve => setTimeout(resolve, 100));

		try {
			console.log("[TS Client] Attempting client.listTools() with 15s timeout...");
			const toolsResult = await client.listTools(undefined, { timeout: 15000 });
			console.log("[TS Client] ✅ client.listTools() successful!");
			console.log("[TS Client] Tools:", JSON.stringify(toolsResult.tools, null, 2));

			if (toolsResult.tools && toolsResult.tools.length > 0) {
				const echoTool = toolsResult.tools.find((tool) => tool.name === 'echo');
				if (echoTool) {
					console.log("[TS Client] Attempting to call echo tool...");
					const callResult = await client.callTool({
						name: "echo",
						arguments: { message: "Hello from TypeScript client via Stdio!" }
					});
					console.log("[TS Client] ✅ Tool call successful!");
					console.log("[TS Client] Result:", JSON.stringify(callResult, null, 2));
				}
			}
		} catch (listToolsError) {
			console.error("[TS Client] ❌ Error during client.listTools():", listToolsError);
			if (listToolsError instanceof z.ZodError) {
				console.error("[TS Client] Zod validation errors:", JSON.stringify(listToolsError.format(), null, 2));
			}
		}

	} catch (connectError) {
		console.error("[TS Client] ❌ Error during client.connect():", connectError);
		if (connectError instanceof z.ZodError) {
			console.error("[TS Client] Zod validation errors:", JSON.stringify(connectError.format(), null, 2));
		}
		process.exit(1); // Exit with error code if connect fails
	} finally {
		console.log("[TS Client] Closing client connection...");
		// client.close() should signal the transport to terminate the child process.
		await client.close();
		console.log("[TS Client] Client connection closed.");
	}
}

console.log("[TS Client] Starting stdio test run...");
runTest().catch(err => {
	console.error("[TS Client] Unhandled error during stdio test run:", err);
	if (err instanceof z.ZodError) {
		console.error("[TS Client] Zod validation errors:", JSON.stringify(err.format(), null, 2));
	}
	process.exit(1);
});
