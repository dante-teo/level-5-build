import Ajv2020, { type ErrorObject } from "ajv/dist/2020";
import schemaJson from "./schema.unstable.json";
import metaJson from "./meta.unstable.json";

type AcpMeta = {
	readonly agentMethods: Record<string, string>;
	readonly clientMethods: Record<string, string>;
	readonly protocolMethods?: Record<string, string>;
	readonly version: number;
};

type ValidationResult =
	| { readonly ok: true }
	| { readonly ok: false; readonly errors: readonly ErrorObject[]; readonly message: string };

const meta = metaJson as AcpMeta;

export const AGENT_METHODS = meta.agentMethods;
export const CLIENT_METHODS = meta.clientMethods;
export const PROTOCOL_VERSION = meta.version;

const ajv = new Ajv2020({
	allErrors: true,
	strict: false,
	allowUnionTypes: true,
	validateFormats: false,
});

ajv.addSchema(schemaJson, "acp");

const validators = new Map<string, ReturnType<typeof ajv.compile>>();

function getValidator(defName: string) {
	const existing = validators.get(defName);
	if (existing) {
		return existing;
	}
	const validate = ajv.compile({ $ref: `acp#/$defs/${defName}` });
	validators.set(defName, validate);
	return validate;
}

function formatErrors(errors: readonly ErrorObject[] | null | undefined): string {
	return (errors ?? [])
		.slice(0, 3)
		.map((error) => `${error.instancePath || "/"} ${error.message ?? "is invalid"}`)
		.join("; ");
}

export function validateAcpPayload(defName: string, payload: unknown): ValidationResult {
	const validate = getValidator(defName);
	if (validate(payload)) {
		return { ok: true };
	}
	const errors = validate.errors ?? [];
	return {
		ok: false,
		errors,
		message: formatErrors(errors) || `Invalid ACP ${defName} payload`,
	};
}

export function assertAcpPayload(defName: string, payload: unknown): void {
	const result = validateAcpPayload(defName, payload);
	if (!result.ok) {
		throw new Error(result.message);
	}
}

const responseDefs = new Map<string, string>([
	[AGENT_METHODS.initialize, "InitializeResponse"],
	[AGENT_METHODS.authenticate, "AuthenticateResponse"],
	[AGENT_METHODS.logout, "LogoutResponse"],
	[AGENT_METHODS.session_new, "NewSessionResponse"],
	[AGENT_METHODS.session_load, "LoadSessionResponse"],
	[AGENT_METHODS.session_list, "ListSessionsResponse"],
	[AGENT_METHODS.session_fork, "ForkSessionResponse"],
	[AGENT_METHODS.session_resume, "ResumeSessionResponse"],
	[AGENT_METHODS.session_close, "CloseSessionResponse"],
	[AGENT_METHODS.session_prompt, "PromptResponse"],
	[AGENT_METHODS.session_set_model, "SetSessionModelResponse"],
	[AGENT_METHODS.session_set_config_option, "SetSessionConfigOptionResponse"],
]);

const requestDefs = new Map<string, string>([
	[AGENT_METHODS.initialize, "InitializeRequest"],
	[AGENT_METHODS.authenticate, "AuthenticateRequest"],
	[AGENT_METHODS.logout, "LogoutRequest"],
	[AGENT_METHODS.session_new, "NewSessionRequest"],
	[AGENT_METHODS.session_load, "LoadSessionRequest"],
	[AGENT_METHODS.session_list, "ListSessionsRequest"],
	[AGENT_METHODS.session_fork, "ForkSessionRequest"],
	[AGENT_METHODS.session_resume, "ResumeSessionRequest"],
	[AGENT_METHODS.session_close, "CloseSessionRequest"],
	[AGENT_METHODS.session_prompt, "PromptRequest"],
	[AGENT_METHODS.session_set_model, "SetSessionModelRequest"],
	[AGENT_METHODS.session_set_config_option, "SetSessionConfigOptionRequest"],
	[CLIENT_METHODS.session_request_permission, "RequestPermissionRequest"],
	[CLIENT_METHODS.session_elicitation, "ElicitationRequest"],
	[CLIENT_METHODS.fs_read_text_file, "ReadTextFileRequest"],
	[CLIENT_METHODS.fs_write_text_file, "WriteTextFileRequest"],
	[CLIENT_METHODS.terminal_create, "CreateTerminalRequest"],
	[CLIENT_METHODS.terminal_output, "TerminalOutputRequest"],
	[CLIENT_METHODS.terminal_wait_for_exit, "WaitForTerminalExitRequest"],
	[CLIENT_METHODS.terminal_kill, "KillTerminalRequest"],
	[CLIENT_METHODS.terminal_release, "ReleaseTerminalRequest"],
]);

const notificationDefs = new Map<string, string>([
	[AGENT_METHODS.session_cancel, "CancelNotification"],
	[CLIENT_METHODS.session_update, "SessionNotification"],
	[CLIENT_METHODS.session_elicitation_complete, "ElicitationCompleteNotification"],
]);

export function getKnownRequestDef(method: string): string | undefined {
	return requestDefs.get(method);
}

export function getKnownResponseDef(method: string): string | undefined {
	return responseDefs.get(method);
}

export function getKnownNotificationDef(method: string): string | undefined {
	return notificationDefs.get(method);
}

export function isKnownClientRequestMethod(method: string): boolean {
	return requestDefs.has(method) && Object.values(CLIENT_METHODS).includes(method);
}
