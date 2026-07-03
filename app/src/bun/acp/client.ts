import { AcpError } from "./errors";
import { AGENT_METHODS, CLIENT_METHODS } from "./schema";
import { AcpJsonRpcTransport, type AcpServerRequest, type JsonValue, type RpcId } from "./transport";

export const ACP_REQUEST_TIMEOUTS_MS = {
	setup: 15_000,
	prompt: 10 * 60 * 1000,
	extension: 30_000,
} as const;

export class AcpClient {
	constructor(private readonly transport: AcpJsonRpcTransport) {}

	initialize(params: JsonValue): Promise<unknown> {
		return this.transport.request(AGENT_METHODS.initialize, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.setup,
		});
	}

	createSession(params: JsonValue): Promise<unknown> {
		return this.transport.request(AGENT_METHODS.session_new, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.setup,
		});
	}

	loadSession(params: JsonValue): Promise<unknown> {
		return this.transport.request(AGENT_METHODS.session_load, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.setup,
		});
	}

	resumeSession(params: JsonValue): Promise<unknown> {
		return this.transport.request(AGENT_METHODS.session_resume, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.setup,
		});
	}

	listSessions(params?: JsonValue): Promise<unknown> {
		return this.transport.request(AGENT_METHODS.session_list, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.setup,
		});
	}

	closeSession(params: JsonValue): Promise<unknown> {
		return this.transport.request(AGENT_METHODS.session_close, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.setup,
		});
	}

	setConfigOption(params: JsonValue): Promise<unknown> {
		return this.transport.request(AGENT_METHODS.session_set_config_option, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.setup,
		});
	}

	prompt(params: JsonValue): Promise<unknown> {
		return this.transport.request(AGENT_METHODS.session_prompt, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.prompt,
		});
	}

	cancel(params: JsonValue): void {
		this.transport.notify(AGENT_METHODS.session_cancel, params);
	}

	requestExtension(method: string, params?: JsonValue): Promise<unknown> {
		return this.transport.request(method, params, {
			timeoutMs: ACP_REQUEST_TIMEOUTS_MS.extension,
		});
	}

	deleteSession(params: JsonValue): Promise<unknown> {
		return this.requestExtension("session/delete", params);
	}

	respondSuccess(id: RpcId, result: unknown): void {
		this.transport.respondSuccess(id, result);
	}

	respondMethodNotFound(request: AcpServerRequest): void {
		this.transport.respondError(request.id, -32601, `Unsupported ACP client request: ${request.method}`);
	}

	static isPermissionRequest(request: AcpServerRequest): boolean {
		return request.method === CLIENT_METHODS.session_request_permission;
	}

	failAll(error: AcpError): void {
		this.transport.failAll(error);
	}
}
