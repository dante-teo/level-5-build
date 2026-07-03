import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AcpMockServer } from "../src/server";
import { StateStore } from "../src/state";
import type { JsonValue, Logger, RpcMessage } from "../src/types";

const silentLogger: Logger = {
	debug() {},
	info() {},
	error() {}
};

let tmp = "";
let originalWrite: typeof process.stdout.write;
let output: string[];

beforeEach(() => {
	tmp = mkdtempSync(join(tmpdir(), "acp-mock-test-"));
	output = [];
	originalWrite = process.stdout.write;
	process.stdout.write = ((chunk: string | Uint8Array) => {
		output.push(String(chunk));
		return true;
	}) as typeof process.stdout.write;
});

afterEach(() => {
	process.stdout.write = originalWrite;
	rmSync(tmp, { recursive: true, force: true });
});

describe("ACP mock server", () => {
	test("initializes with Devin-like app-relevant capabilities and no advertised mock surface", async () => {
		const server = createServer();
		await send(server, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1, clientCapabilities: {} } });

		const response = messages().at(-1) as Record<string, JsonValue>;
		const result = response.result as Record<string, JsonValue>;
		const capabilities = result.agentCapabilities as Record<string, JsonValue>;
		expect(result.protocolVersion).toBe(1);
		expect((capabilities.sessionCapabilities as Record<string, JsonValue>).list).toEqual({});
		expect(capabilities._meta).toBeUndefined();
		expect(capabilities.mcpCapabilities).toBeUndefined();
		expect(result.authMethods).toBeUndefined();
	});

	test("creates sessions with model config and core slash command update", async () => {
		const server = createServer();
		await initialize(server);
		await send(server, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: tmp, mcpServers: [] } });

		const all = messages();
		const response = all.find((message) => (message as Record<string, JsonValue>).id === 2) as Record<string, JsonValue>;
		const result = response.result as Record<string, JsonValue>;
		expect(typeof result.sessionId).toBe("string");
		const configOptions = result.configOptions as Array<Record<string, JsonValue>>;
		expect(configOptions.map((option) => option.id)).toEqual(["model"]);
		expect((all.at(-1) as Record<string, JsonValue>).id).toBe(response.id);
		await Bun.sleep(1);
		const commandUpdate = messages().find((message) => JSON.stringify(message).includes("available_commands_update")) as Record<string, JsonValue>;
		const commands = (((commandUpdate.params as Record<string, JsonValue>).update as Record<string, JsonValue>).availableCommands as Array<Record<string, JsonValue>>);
		expect(commands.map((command) => command.name)).toEqual(["help", "plan", "review", "fix", "test"]);
		expect(JSON.stringify(messages())).toContain("config_option_update");
	});

	test("supports direct model listing and config-option model switching", async () => {
		const server = createServer();
		await initialize(server);
		const sessionId = await createSession(server);

		await send(server, { jsonrpc: "2.0", id: 3, method: "_mock/list_models", params: { sessionId } });
		expect(JSON.stringify(messages().at(-1))).toContain("mock-deep");

		await send(server, { jsonrpc: "2.0", id: 30, method: "_mock/list_slash_commands", params: { sessionId } });
		const commandsResponse = messages().find((message) => (message as Record<string, JsonValue>).id === 30) as Record<string, JsonValue>;
		const extensionCommands = ((commandsResponse.result as Record<string, JsonValue>).availableCommands as Array<Record<string, JsonValue>>).map((command) => command.name);
		expect(extensionCommands).toContain("fail");
		expect(extensionCommands).toContain("tokens");

		await send(server, {
			jsonrpc: "2.0",
			id: 4,
			method: "session/set_config_option",
			params: { sessionId, configId: "model", value: "mock-deep" }
		});
		const response = messages().find((message) => (message as Record<string, JsonValue>).id === 4) as Record<string, JsonValue>;
		expect(JSON.stringify(response)).toContain("mock-deep");
	});

	test("uses the selected model context window for usage updates", async () => {
		const server = createServer(0);
		await initialize(server);
		const sessionId = await createSession(server);
		await send(server, {
			jsonrpc: "2.0",
			id: 4,
			method: "session/set_config_option",
			params: { sessionId, configId: "model", value: "mock-deep" }
		});
		await send(server, {
			jsonrpc: "2.0",
			id: 5,
			method: "session/prompt",
			params: { sessionId, prompt: [{ type: "text", text: "/test please" }] }
		});

		const usageUpdate = messages().find((message) => JSON.stringify(message).includes("usage_update")) as Record<string, JsonValue>;
		const update = (usageUpdate.params as Record<string, JsonValue>).update as Record<string, JsonValue>;
		expect(update.size).toBe(1000000);
	});

	test("streams realistic prompt updates and ends the turn", async () => {
		const server = createServer(0);
		await initialize(server);
		const sessionId = await createSession(server);

		const prompt = send(server, {
			jsonrpc: "2.0",
			id: 5,
			method: "session/prompt",
			params: { sessionId, prompt: [{ type: "text", text: "/fix a layout bug" }] }
		});

		const permissionRequest = await waitForMessage(
			(message) => (message as Record<string, JsonValue>).method === "session/request_permission"
		) as Record<string, JsonValue>;
		expect(permissionRequest).toBeTruthy();
		await send(server, { jsonrpc: "2.0", id: permissionRequest.id as number, result: { outcome: { optionId: "allow-once" } } });
		await prompt;

		const all = JSON.stringify(messages());
		expect(all).toContain("plan");
		expect(all).toContain("tool_call");
		expect(all).toContain("session/request_permission");
		expect(all).toContain("diff");
		expect(all).toContain("\"stopReason\":\"end_turn\"");
	});

	test("rejecting the edit permission request stops without a diff", async () => {
		const server = createServer(0);
		await initialize(server);
		const sessionId = await createSession(server);

		const prompt = send(server, {
			jsonrpc: "2.0",
			id: 5,
			method: "session/prompt",
			params: { sessionId, prompt: [{ type: "text", text: "/fix a layout bug" }] }
		});

		const permissionRequest = await waitForMessage(
			(message) => (message as Record<string, JsonValue>).method === "session/request_permission"
		) as Record<string, JsonValue>;
		expect(permissionRequest).toBeTruthy();
		await send(server, { jsonrpc: "2.0", id: permissionRequest.id as number, result: { outcome: { optionId: "reject-once" } } });
		await prompt;

		const all = JSON.stringify(messages());
		expect(all).toContain("\"status\":\"failed\"");
		expect(all).not.toContain("\"type\":\"diff\"");
		expect(all).toContain("\"stopReason\":\"end_turn\"");
	});

	test("lists and loads persisted sessions", async () => {
		const statePath = join(tmp, "state.json");
		const first = createServer(0, statePath);
		await initialize(first);
		const sessionId = await createSession(first);
		await send(first, {
			jsonrpc: "2.0",
			id: 5,
			method: "session/prompt",
			params: { sessionId, prompt: [{ type: "text", text: "hello" }] }
		});

		output = [];
		const second = createServer(0, statePath);
		await initialize(second);
		await send(second, { jsonrpc: "2.0", id: 6, method: "session/list", params: { cwd: tmp } });
		expect(JSON.stringify(messages().at(-1))).toContain(sessionId);

		await send(second, { jsonrpc: "2.0", id: 7, method: "session/load", params: { sessionId, cwd: tmp, mcpServers: [] } });
		expect(JSON.stringify(messages())).toContain("agent_message_chunk");
	});

	test("cancels an active prompt with cancelled stop reason", async () => {
		const server = createServer(20);
		await initialize(server);
		const sessionId = await createSession(server);

		const prompt = send(server, {
			jsonrpc: "2.0",
			id: 8,
			method: "session/prompt",
			params: { sessionId, prompt: [{ type: "text", text: "/test please" }] }
		});
		await Bun.sleep(5);
		await send(server, { jsonrpc: "2.0", method: "session/cancel", params: { sessionId } });
		await prompt;
		expect(JSON.stringify(messages())).toContain("\"stopReason\":\"cancelled\"");
	});

	test("keeps hidden QA prompt triggers without advertising them as slash commands", async () => {
		const server = createServer(0);
		await initialize(server);
		const sessionId = await createSession(server);
		output = [];

		await send(server, {
			jsonrpc: "2.0",
			id: 9,
			method: "session/prompt",
			params: { sessionId, prompt: [{ type: "text", text: "please fail" }] }
		});
		await send(server, {
			jsonrpc: "2.0",
			id: 10,
			method: "session/prompt",
			params: { sessionId, prompt: [{ type: "text", text: "refuse this" }] }
		});
		await send(server, {
			jsonrpc: "2.0",
			id: 11,
			method: "session/prompt",
			params: { sessionId, prompt: [{ type: "text", text: "max tokens" }] }
		});

		const all = JSON.stringify(messages());
		expect(all).toContain("\"status\":\"failed\"");
		expect(all).toContain("\"stopReason\":\"refusal\"");
		expect(all).toContain("\"stopReason\":\"max_tokens\"");
	});
});

function createServer(delayMs = 0, statePath = join(tmp, "state.json")): AcpMockServer {
	return new AcpMockServer(new StateStore(statePath), silentLogger, delayMs);
}

async function initialize(server: AcpMockServer): Promise<void> {
	await send(server, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1, clientCapabilities: {} } });
}

async function createSession(server: AcpMockServer): Promise<string> {
	await send(server, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: tmp, mcpServers: [] } });
	const response = messages().find((message) => (message as Record<string, JsonValue>).id === 2) as Record<string, JsonValue>;
	return String((response.result as Record<string, JsonValue>).sessionId);
}

async function send(server: AcpMockServer, message: RpcMessage): Promise<void> {
	await server.handleLine(JSON.stringify(message));
}

function messages(): RpcMessage[] {
	return output
		.join("")
		.split("\n")
		.filter(Boolean)
		.map((line) => JSON.parse(line) as RpcMessage);
}

async function waitForMessage(predicate: (message: RpcMessage) => boolean, timeoutMs = 1000): Promise<RpcMessage | undefined> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const message = messages().find(predicate);
		if (message) return message;
		await Bun.sleep(1);
	}
	return undefined;
}
