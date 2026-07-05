export type AcpErrorCode =
	| "spawn_failure"
	| "process_exit"
	| "request_timeout"
	| "malformed_json"
	| "schema_validation"
	| "unsupported_method"
	| "transport_failure";

export class AcpError extends Error {
	constructor(
		readonly code: AcpErrorCode,
		message: string,
		readonly data?: unknown,
	) {
		super(message);
		this.name = "AcpError";
	}
}

export function toUserMessage(error: unknown): string {
	if (error instanceof AcpError) {
		return error.message;
	}
	return error instanceof Error ? error.message : "Agent ACP request failed.";
}
