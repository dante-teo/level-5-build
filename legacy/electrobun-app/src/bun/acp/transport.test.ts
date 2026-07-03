import { describe, expect, test } from "bun:test";
import { AcpError } from "./errors";
import { AGENT_METHODS, CLIENT_METHODS, validateAcpPayload } from "./schema";
import { AcpJsonRpcTransport } from "./transport";

const parseLine = (line: string) => JSON.parse(line) as Record<string, unknown>;

describe("ACP schema validation", () => {
	test("validates known response payloads against the vendored ACP schema", () => {
		const valid = validateAcpPayload("InitializeResponse", {
			protocolVersion: 1,
			agentCapabilities: {},
		});
		expect(valid.ok).toBe(true);

		const invalid = validateAcpPayload("InitializeResponse", {
			protocolVersion: "1",
			agentCapabilities: {},
		});
		expect(invalid.ok).toBe(false);
	});
});

describe("AcpJsonRpcTransport", () => {
	test("resolves requests and clears pending state", async () => {
		const writes: string[] = [];
		const transport = new AcpJsonRpcTransport({ writeLine: (line) => writes.push(line) });
		const promise = transport.request(AGENT_METHODS.initialize, {
			protocolVersion: 1,
			clientInfo: { name: "test", version: "0.0.0" },
			clientCapabilities: {},
		});
		const request = parseLine(writes[0] ?? "");
		transport.receiveLine(
			JSON.stringify({
				jsonrpc: "2.0",
				id: request.id,
				result: { protocolVersion: 1, agentCapabilities: {} },
			}),
		);

		await expect(promise).resolves.toEqual({ protocolVersion: 1, agentCapabilities: {} });
		expect(transport.pendingCount).toBe(0);
	});

	test("times out requests and clears pending state", async () => {
		const transport = new AcpJsonRpcTransport({ writeLine: () => undefined });
		const promise = transport.request("_mock/list_skills", undefined, { timeoutMs: 5 });
		await expect(promise).rejects.toMatchObject({ code: "request_timeout" });
		expect(transport.pendingCount).toBe(0);
	});

	test("rejects all pending requests once on process exit", async () => {
		const transport = new AcpJsonRpcTransport({ writeLine: () => undefined });
		const first = transport.request("_mock/list_skills");
		const second = transport.request("_mock/list_slash_commands");
		transport.failAll(new AcpError("process_exit", "ACP process exited with code 9"));

		await expect(first).rejects.toMatchObject({ code: "process_exit" });
		await expect(second).rejects.toMatchObject({ code: "process_exit" });
		expect(transport.pendingCount).toBe(0);
	});

	test("emits recoverable diagnostics for malformed JSON", () => {
		const diagnostics: string[] = [];
		const transport = new AcpJsonRpcTransport({
			writeLine: () => undefined,
			onDiagnostic: (event) => diagnostics.push(event.error.code),
		});

		transport.receiveLine("{not json");

		expect(diagnostics).toEqual(["malformed_json"]);
		expect(transport.pendingCount).toBe(0);
	});

	test("fails transport on oversized unterminated stdout buffers", () => {
		const diagnostics: string[] = [];
		const transport = new AcpJsonRpcTransport({
			writeLine: () => undefined,
			maxBufferBytes: 8,
			onDiagnostic: (event) => diagnostics.push(event.error.code),
		});

		transport.receiveChunk("unterminated");

		expect(diagnostics).toEqual(["transport_failure"]);
	});

	test("keeps unknown extension notifications non-fatal", () => {
		const notifications: string[] = [];
		const diagnostics: string[] = [];
		const transport = new AcpJsonRpcTransport({
			writeLine: () => undefined,
			onNotification: (event) => notifications.push(event.method),
			onDiagnostic: (event) => diagnostics.push(event.error.code),
		});

		transport.receiveLine(JSON.stringify({ jsonrpc: "2.0", method: "vendor/custom", params: { ok: true } }));

		expect(notifications).toEqual(["vendor/custom"]);
		expect(diagnostics).toEqual([]);
	});

	test("buffers notifications until a handler is registered", () => {
		const notifications: string[] = [];
		const transport = new AcpJsonRpcTransport({ writeLine: () => undefined });

		transport.receiveLine(JSON.stringify({ jsonrpc: "2.0", method: "vendor/early", params: { ok: true } }));
		transport.setNotificationHandler((event) => notifications.push(event.method));

		expect(notifications).toEqual(["vendor/early"]);
	});

	test("returns method-not-found for unknown extension requests", () => {
		const writes: string[] = [];
		const transport = new AcpJsonRpcTransport({ writeLine: (line) => writes.push(line) });

		transport.receiveLine(JSON.stringify({ jsonrpc: "2.0", id: "abc", method: "vendor/custom", params: {} }));

		expect(parseLine(writes[0] ?? "")).toMatchObject({
			jsonrpc: "2.0",
			id: "abc",
			error: { code: -32601 },
		});
	});

	test("validates known server requests before dispatch", () => {
		const diagnostics: string[] = [];
		const transport = new AcpJsonRpcTransport({
			writeLine: () => undefined,
			onDiagnostic: (event) => diagnostics.push(event.error.code),
		});

		transport.receiveLine(
			JSON.stringify({
				jsonrpc: "2.0",
				id: 3,
				method: CLIENT_METHODS.session_request_permission,
				params: { sessionId: 123 },
			}),
		);

		expect(diagnostics).toEqual(["schema_validation"]);
	});

	test("can send cancel before rejecting an in-flight prompt", async () => {
		const writes: string[] = [];
		const transport = new AcpJsonRpcTransport({ writeLine: (line) => writes.push(line) });
		const prompt = transport.request(AGENT_METHODS.session_prompt, {
			sessionId: "session-1",
			prompt: [{ type: "text", text: "hello" }],
		});
		transport.notify(AGENT_METHODS.session_cancel, { sessionId: "session-1" });
		transport.failAll(new AcpError("request_timeout", "timed out"));

		await expect(prompt).rejects.toMatchObject({ code: "request_timeout" });
		expect(writes.map((line) => parseLine(line).method)).toEqual(["session/prompt", "session/cancel"]);
		expect(transport.pendingCount).toBe(0);
	});
});
