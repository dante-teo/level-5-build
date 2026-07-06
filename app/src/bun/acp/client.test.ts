import { describe, expect, test } from "bun:test";
import { AGENT_METHODS } from "./schema";
import { ACP_REQUEST_TIMEOUTS_MS, AcpClient } from "./client";
import { AcpJsonRpcTransport } from "./transport";

const parseLine = (line: string) => JSON.parse(line) as Record<string, unknown>;

describe("AcpClient", () => {
	// Regression guard for the bug documented in AGENTS.md: session/prompt
	// doesn't resolve until the entire turn completes, which routinely
	// exceeds a short RPC default. Binding it to a short timeout causes the
	// request to time out and get reported as "Prompt failed" while the
	// agent keeps working -- detecting a truly stuck turn is
	// AcpTurnIdleWatchdog's job, not this timeout's.
	test("session/prompt uses a generous timeout, not the setup/extension default", () => {
		expect(ACP_REQUEST_TIMEOUTS_MS.prompt).toBeGreaterThanOrEqual(60 * 60 * 1000);
		expect(ACP_REQUEST_TIMEOUTS_MS.prompt).toBeGreaterThan(ACP_REQUEST_TIMEOUTS_MS.setup);
		expect(ACP_REQUEST_TIMEOUTS_MS.prompt).toBeGreaterThan(ACP_REQUEST_TIMEOUTS_MS.extension);
	});

	test("sends an empty object for session/list params when no cursor is provided", () => {
		const writes: string[] = [];
		const transport = new AcpJsonRpcTransport({ writeLine: (line) => writes.push(line) });
		const client = new AcpClient(transport);

		const response = client.listSessions();
		const request = parseLine(writes[0] ?? "");

		expect(request).toMatchObject({
			method: AGENT_METHODS.session_list,
			params: {},
		});
		transport.receiveLine(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { sessions: [] } }));
		return expect(response).resolves.toEqual({ sessions: [] });
	});
});
