import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";

// These tests drive the real `start.sh` entrypoint over a stdio
// subprocess, unlike server.test.ts which calls AcpMockServer.handleLine()
// directly in-process. That distinction matters: a request handler that
// calls back into the client mid-flight (e.g. session/prompt triggering
// session/request_permission) only deadlocks if the stdin-reading loop in
// runServer() blocks on fully finishing one line before reading the next.
// In-process tests can't observe that class of bug because they never go
// through runServer()'s loop at all.

let tmp = "";

beforeEach(() => {
	tmp = mkdtempSync(join(tmpdir(), "acp-mock-subprocess-test-"));
});

afterEach(() => {
	rmSync(tmp, { recursive: true, force: true });
});

type Client = {
	send: (method: string, params?: unknown) => Promise<any>;
	notify: (method: string, params?: unknown) => void;
	respond: (id: number | string, result: unknown) => void;
	waitForRequest: (method: string, timeoutMs?: number) => Promise<any>;
	kill: () => void;
};

function spawnClient(env: Record<string, string> = {}): Client {
	const proc = spawn("./start.sh", {
		cwd: process.cwd(),
		stdio: ["pipe", "pipe", "ignore"],
		env: { ...process.env, ACP_MOCK_STATE_PATH: join(tmp, "state.json"), ACP_MOCK_DELAY_MS: "10", ...env }
	});

	let nextId = 1;
	const pendingResponses = new Map<number, (message: any) => void>();
	const pendingServerRequests: any[] = [];
	const requestWaiters: Array<{ method: string; resolve: (message: any) => void }> = [];
	let buffer = "";

	(async () => {
		for await (const chunk of proc.stdout) {
			buffer += chunk.toString("utf8");
			let index: number;
			while ((index = buffer.indexOf("\n")) >= 0) {
				const line = buffer.slice(0, index).trim();
				buffer = buffer.slice(index + 1);
				if (!line) continue;
				const message = JSON.parse(line);
				if ("id" in message && ("result" in message || "error" in message) && pendingResponses.has(message.id)) {
					pendingResponses.get(message.id)!(message);
					pendingResponses.delete(message.id);
					continue;
				}
				if ("method" in message && "id" in message) {
					const waiterIndex = requestWaiters.findIndex((waiter) => waiter.method === message.method);
					if (waiterIndex >= 0) {
						const [waiter] = requestWaiters.splice(waiterIndex, 1);
						waiter.resolve(message);
					} else {
						pendingServerRequests.push(message);
					}
				}
			}
		}
	})();

	return {
		send(method, params) {
			const id = nextId++;
			proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
			return new Promise((resolve) => pendingResponses.set(id, resolve));
		},
		notify(method, params) {
			proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
		},
		respond(id, result) {
			// Answers a request the *server* initiated (e.g. session/request_permission),
			// as opposed to send(), which always originates a new client request.
			proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
		},
		waitForRequest(method, timeoutMs = 3000) {
			const alreadyQueuedIndex = pendingServerRequests.findIndex((message) => message.method === method);
			if (alreadyQueuedIndex >= 0) {
				const [message] = pendingServerRequests.splice(alreadyQueuedIndex, 1);
				return Promise.resolve(message);
			}
			return new Promise((resolve, reject) => {
				const timer = setTimeout(() => reject(new Error(`timed out waiting for ${method}`)), timeoutMs);
				requestWaiters.push({
					method,
					resolve: (message) => {
						clearTimeout(timer);
						resolve(message);
					}
				});
			});
		},
		kill() {
			proc.kill();
		}
	};
}

async function initializeAndCreateSession(client: Client, cwd: string): Promise<string> {
	await client.send("initialize", { protocolVersion: 1, clientInfo: { name: "test", version: "0.0.0" }, clientCapabilities: {} });
	const sessionResult = await client.send("session/new", { cwd, mcpServers: [] });
	return sessionResult.result.sessionId as string;
}

describe("ACP mock server over a real subprocess", () => {
	test("answering a mid-turn session/request_permission does not deadlock the prompt", async () => {
		const client = spawnClient();
		try {
			const sessionId = await initializeAndCreateSession(client, tmp);
			const promptPromise = client.send("session/prompt", {
				sessionId,
				prompt: [{ type: "text", text: "/fix a layout bug" }]
			});

			const permissionRequest = await client.waitForRequest("session/request_permission");
			client.respond(permissionRequest.id, { outcome: { optionId: "allow-once" } });

			const result = await promptPromise;
			assert.equal(result.result.stopReason, "end_turn");
		} finally {
			client.kill();
		}
	});

	test("rejecting a mid-turn session/request_permission still resolves the prompt", async () => {
		const client = spawnClient();
		try {
			const sessionId = await initializeAndCreateSession(client, tmp);
			const promptPromise = client.send("session/prompt", {
				sessionId,
				prompt: [{ type: "text", text: "/fix a layout bug" }]
			});

			const permissionRequest = await client.waitForRequest("session/request_permission");
			client.respond(permissionRequest.id, { outcome: { optionId: "reject-once" } });

			const result = await promptPromise;
			assert.equal(result.result.stopReason, "end_turn");
		} finally {
			client.kill();
		}
	});

	test("cancelling a prompt still resolves over the real subprocess", async () => {
		const client = spawnClient();
		try {
			const sessionId = await initializeAndCreateSession(client, tmp);
			const promptPromise = client.send("session/prompt", { sessionId, prompt: [{ type: "text", text: "/test please" }] });
			await sleep(30);
			client.notify("session/cancel", { sessionId });

			const result = await promptPromise;
			assert.equal(result.result.stopReason, "cancelled");
		} finally {
			client.kill();
		}
	});
});

function sleep(milliseconds: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
