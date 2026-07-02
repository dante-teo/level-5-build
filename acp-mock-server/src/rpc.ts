import type { JsonValue, Logger, RpcError, RpcId, RpcMessage, RpcNotification, RpcResponse, RpcSuccess } from "./types";

export const JsonRpcErrorCode = {
	ParseError: -32700,
	InvalidRequest: -32600,
	MethodNotFound: -32601,
	InvalidParams: -32602,
	InternalError: -32603
} as const;

export class RpcException extends Error {
	constructor(
		readonly code: number,
		message: string,
		readonly data?: JsonValue
	) {
		super(message);
	}
}

export function makeSuccess(id: RpcId, result: JsonValue): RpcSuccess {
	return { jsonrpc: "2.0", id, result };
}

export function makeError(id: RpcId, code: number, message: string, data?: JsonValue): RpcError {
	return {
		jsonrpc: "2.0",
		id,
		error: data === undefined ? { code, message } : { code, message, data }
	};
}

export function isRpcResponse(message: RpcMessage): message is RpcResponse {
	return !("method" in message) && "id" in message && ("result" in message || "error" in message);
}

export function isRpcRequest(message: RpcMessage): message is import("./types").RpcRequest {
	return "method" in message && "id" in message && !("result" in message) && !("error" in message);
}

export function isRpcNotification(message: RpcMessage): message is RpcNotification {
	return "method" in message && !("id" in message);
}

export function parseRpcLine(line: string): RpcMessage {
	const parsed = JSON.parse(line) as unknown;
	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw new RpcException(JsonRpcErrorCode.InvalidRequest, "JSON-RPC message must be an object");
	}
	const record = parsed as Record<string, unknown>;
	if (record.jsonrpc !== "2.0") {
		throw new RpcException(JsonRpcErrorCode.InvalidRequest, "JSON-RPC message must include jsonrpc: \"2.0\"");
	}
	if ("method" in record && typeof record.method !== "string") {
		throw new RpcException(JsonRpcErrorCode.InvalidRequest, "JSON-RPC method must be a string");
	}
	return parsed as RpcMessage;
}

export function writeMessage(message: RpcMessage): void {
	process.stdout.write(`${JSON.stringify(message)}\n`);
}

export function notify(method: string, params?: JsonValue): void {
	writeMessage(params === undefined ? { jsonrpc: "2.0", method } : { jsonrpc: "2.0", method, params });
}

export function respond(id: RpcId, result: JsonValue): void {
	writeMessage(makeSuccess(id, result));
}

export function respondError(id: RpcId, error: unknown, fallbackMessage = "Internal error"): void {
	if (error instanceof RpcException) {
		writeMessage(makeError(id, error.code, error.message, error.data));
		return;
	}
	const message = error instanceof Error ? error.message : fallbackMessage;
	writeMessage(makeError(id, JsonRpcErrorCode.InternalError, message));
}

export function createLogger(level: string | undefined): Logger {
	const normalized = level ?? "info";
	const enabled = {
		debug: normalized === "debug",
		info: normalized === "debug" || normalized === "info",
		error: normalized !== "silent"
	};
	return {
		debug(message) {
			if (enabled.debug) process.stderr.write(`[acp-mock debug] ${message}\n`);
		},
		info(message) {
			if (enabled.info) process.stderr.write(`[acp-mock] ${message}\n`);
		},
		error(message) {
			if (enabled.error) process.stderr.write(`[acp-mock error] ${message}\n`);
		}
	};
}
