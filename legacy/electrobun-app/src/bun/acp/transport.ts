import { AcpError } from "./errors";
import {
	getKnownNotificationDef,
	getKnownRequestDef,
	getKnownResponseDef,
	isKnownClientRequestMethod,
	validateAcpPayload,
} from "./schema";

export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };
export type RpcId = string | number | null;

type RpcRequest = {
	readonly jsonrpc: "2.0";
	readonly id: RpcId;
	readonly method: string;
	readonly params?: unknown;
};

type RpcNotification = {
	readonly jsonrpc: "2.0";
	readonly method: string;
	readonly params?: unknown;
};

type RpcResponse =
	| { readonly jsonrpc: "2.0"; readonly id: RpcId; readonly result: unknown }
	| { readonly jsonrpc: "2.0"; readonly id: RpcId; readonly error: { readonly code: number; readonly message: string; readonly data?: unknown } };

type PendingRequest = {
	readonly method: string;
	readonly resolve: (value: unknown) => void;
	readonly reject: (error: AcpError) => void;
	readonly timer: ReturnType<typeof setTimeout>;
};

export type AcpTransportDiagnostic = {
	readonly error: AcpError;
	readonly line?: string;
};

export type AcpServerRequest = {
	readonly id: RpcId;
	readonly method: string;
	readonly params?: unknown;
};

export type AcpNotification = {
	readonly method: string;
	readonly params?: unknown;
};

export type AcpJsonRpcTransportOptions = {
	readonly writeLine: (line: string) => void;
	readonly onServerRequest?: (request: AcpServerRequest) => void;
	readonly onNotification?: (notification: AcpNotification) => void;
	readonly onDiagnostic?: (event: AcpTransportDiagnostic) => void;
	readonly onActivity?: () => void;
	readonly maxBufferBytes?: number;
	readonly defaultTimeoutMs?: number;
};

const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const DEFAULT_MAX_BUFFER_BYTES = 1024 * 1024;

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRpcResponse(value: unknown): value is RpcResponse {
	return (
		isRecord(value) &&
		value.jsonrpc === "2.0" &&
		"id" in value &&
		("result" in value || "error" in value)
	);
}

function isRpcRequest(value: unknown): value is RpcRequest {
	return (
		isRecord(value) &&
		value.jsonrpc === "2.0" &&
		"id" in value &&
		typeof value.method === "string" &&
		!("result" in value) &&
		!("error" in value)
	);
}

function isRpcNotification(value: unknown): value is RpcNotification {
	return (
		isRecord(value) &&
		value.jsonrpc === "2.0" &&
		!("id" in value) &&
		typeof value.method === "string"
	);
}

function rpcIdKey(id: RpcId): string {
	return `${typeof id}:${String(id)}`;
}

export class AcpJsonRpcTransport {
	private nextId = 1;
	private buffer = "";
	private notificationHandler: ((notification: AcpNotification) => void) | undefined;
	private serverRequestHandler: ((request: AcpServerRequest) => void) | undefined;
	private readonly bufferedNotifications: AcpNotification[] = [];
	private readonly pending = new Map<string, PendingRequest>();

	constructor(private readonly options: AcpJsonRpcTransportOptions) {
		this.notificationHandler = options.onNotification;
		this.serverRequestHandler = options.onServerRequest;
	}

	get pendingCount(): number {
		return this.pending.size;
	}

	setNotificationHandler(handler: (notification: AcpNotification) => void): void {
		this.notificationHandler = handler;
		const buffered = this.bufferedNotifications.splice(0, this.bufferedNotifications.length);
		for (const notification of buffered) {
			handler(notification);
		}
	}

	setServerRequestHandler(handler: (request: AcpServerRequest) => void): void {
		this.serverRequestHandler = handler;
	}

	request(method: string, params?: unknown, options: { readonly timeoutMs?: number } = {}): Promise<unknown> {
		const requestDef = getKnownRequestDef(method);
		if (requestDef) {
			const validation = validateAcpPayload(requestDef, params ?? {});
			if (!validation.ok) {
				return Promise.reject(
					new AcpError("schema_validation", `Invalid ${method} request: ${validation.message}`),
				);
			}
		}

		const id = this.nextId++;
		const timeoutMs = options.timeoutMs ?? this.options.defaultTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
		this.options.writeLine(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
		return new Promise((resolve, reject) => {
			const key = rpcIdKey(id);
			const timer = setTimeout(() => {
				const pending = this.pending.get(key);
				if (!pending) {
					return;
				}
				this.pending.delete(key);
				pending.reject(new AcpError("request_timeout", `ACP request timed out: ${method}`));
			}, timeoutMs);
			this.pending.set(key, {
				method,
				resolve,
				reject,
				timer,
			});
		});
	}

	notify(method: string, params?: unknown): void {
		const notificationDef = getKnownNotificationDef(method);
		if (notificationDef) {
			const validation = validateAcpPayload(notificationDef, params ?? {});
			if (!validation.ok) {
				throw new AcpError("schema_validation", `Invalid ${method} notification: ${validation.message}`);
			}
		}
		this.options.writeLine(JSON.stringify({ jsonrpc: "2.0", method, params }));
	}

	respondSuccess(id: RpcId, result: unknown): void {
		this.options.writeLine(JSON.stringify({ jsonrpc: "2.0", id, result }));
	}

	respondError(id: RpcId, code: number, message: string, data?: unknown): void {
		this.options.writeLine(
			JSON.stringify({
				jsonrpc: "2.0",
				id,
				error: {
					code,
					message,
					...(data !== undefined ? { data } : {}),
				},
			}),
		);
	}

	receiveChunk(chunk: string): void {
		this.buffer += chunk;
		if (this.buffer.length > (this.options.maxBufferBytes ?? DEFAULT_MAX_BUFFER_BYTES)) {
			const error = new AcpError("transport_failure", "ACP stdout buffer exceeded the maximum size without a newline.");
			this.emitDiagnostic(error);
			this.failAll(error);
			this.buffer = "";
			return;
		}

		let newlineIndex = this.buffer.indexOf("\n");
		while (newlineIndex >= 0) {
			const line = this.buffer.slice(0, newlineIndex).trim();
			this.buffer = this.buffer.slice(newlineIndex + 1);
			if (line) {
				this.receiveLine(line);
			}
			newlineIndex = this.buffer.indexOf("\n");
		}
	}

	receiveLine(line: string): void {
		let parsed: unknown;
		try {
			parsed = JSON.parse(line);
		} catch {
			this.emitDiagnostic(new AcpError("malformed_json", `Malformed ACP JSON: ${line.slice(0, 120)}`), line);
			return;
		}
		this.options.onActivity?.();

		if (isRpcResponse(parsed)) {
			this.handleResponse(parsed);
			return;
		}
		if (isRpcRequest(parsed)) {
			this.handleServerRequest(parsed);
			return;
		}
		if (isRpcNotification(parsed)) {
			this.handleNotification(parsed);
			return;
		}
		this.emitDiagnostic(new AcpError("malformed_json", "ACP message was not a JSON-RPC request, response, or notification."), line);
	}

	failAll(error: AcpError): void {
		const pending = [...this.pending.values()];
		this.pending.clear();
		for (const entry of pending) {
			clearTimeout(entry.timer);
			entry.reject(error);
		}
	}

	private handleResponse(message: RpcResponse): void {
		const pending = this.pending.get(rpcIdKey(message.id));
		if (!pending) {
			return;
		}
		this.pending.delete(rpcIdKey(message.id));
		clearTimeout(pending.timer);
		if ("error" in message) {
			pending.reject(new AcpError("transport_failure", message.error.message, message.error));
			return;
		}

		const responseDef = getKnownResponseDef(pending.method);
		if (responseDef) {
			const validation = validateAcpPayload(responseDef, message.result);
			if (!validation.ok) {
				pending.reject(
					new AcpError("schema_validation", `Invalid ${pending.method} response: ${validation.message}`, validation.errors),
				);
				return;
			}
		}
		pending.resolve(message.result);
	}

	private handleServerRequest(message: RpcRequest): void {
		const requestDef = getKnownRequestDef(message.method);
		if (requestDef) {
			const validation = validateAcpPayload(requestDef, message.params ?? {});
			if (!validation.ok) {
				const error = new AcpError("schema_validation", `Invalid ${message.method} request: ${validation.message}`, validation.errors);
				this.emitDiagnostic(error);
				this.respondError(message.id, -32602, error.message);
				return;
			}
		}

		if (!isKnownClientRequestMethod(message.method)) {
			this.respondError(message.id, -32601, `Unsupported ACP client request: ${message.method}`);
			return;
		}
		if (!this.serverRequestHandler) {
			this.respondError(message.id, -32601, `Unsupported ACP client request: ${message.method}`);
			return;
		}
		this.serverRequestHandler({
			id: message.id,
			method: message.method,
			params: message.params,
		});
	}

	private handleNotification(message: RpcNotification): void {
		const notificationDef = getKnownNotificationDef(message.method);
		if (notificationDef) {
			const validation = validateAcpPayload(notificationDef, message.params ?? {});
			if (!validation.ok) {
				this.emitDiagnostic(
					new AcpError("schema_validation", `Invalid ${message.method} notification: ${validation.message}`, validation.errors),
				);
				return;
			}
		}
		const notification = { method: message.method, params: message.params };
		if (!this.notificationHandler) {
			this.bufferedNotifications.push(notification);
			return;
		}
		this.notificationHandler(notification);
	}

	private emitDiagnostic(error: AcpError, line?: string): void {
		this.options.onDiagnostic?.({ error, line });
	}
}
