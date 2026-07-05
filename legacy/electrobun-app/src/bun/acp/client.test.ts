import { describe, expect, test } from "bun:test";
import { AGENT_METHODS } from "./schema";
import { AcpClient } from "./client";
import { AcpJsonRpcTransport } from "./transport";

const parseLine = (line: string) => JSON.parse(line) as Record<string, unknown>;

describe("AcpClient", () => {
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
