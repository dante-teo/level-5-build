import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import type { AcpProviderId, ApprovalModeId, AgentPermissionOption } from "../../shared/rpc";

export type AgentPermissionMode = "normal" | "bypass";
export type AgentBackendId = "devin" | "mock" | "omp";

export type AgentSpawnOptions = {
	cmd: string[];
	cwd: string;
	env: NodeJS.ProcessEnv;
};

export const DEFAULT_APPROVAL_MODE: ApprovalModeId = "ask";
export const SETTINGS_KEY_ACP_PROVIDER = "acpProvider";
export const DEFAULT_ACP_PROVIDER: AcpProviderId = "devin";

const APPROVAL_MODES = new Set<ApprovalModeId>(["ask", "auto", "full-access"]);
const USE_ACP_MOCK_VALUE = "1";

export function normalizeApprovalMode(mode: string | undefined): ApprovalModeId {
	return APPROVAL_MODES.has(mode as ApprovalModeId) ? (mode as ApprovalModeId) : DEFAULT_APPROVAL_MODE;
}

export function normalizeAcpProvider(value: string | null | undefined): AcpProviderId {
	return value === "omp" ? "omp" : DEFAULT_ACP_PROVIDER;
}

export function devinPermissionMode(mode: ApprovalModeId): AgentPermissionMode {
	return mode === "full-access" ? "bypass" : "normal";
}

export function resolveAgentCwd(cwd: string | null | undefined): string {
	if (!cwd || cwd.trim().length === 0 || cwd.trim() === "~/" || cwd.trim() === "~") {
		return homedir();
	}
	if (cwd.startsWith("~/")) {
		return resolve(homedir(), cwd.slice(2));
	}
	return cwd;
}

export function buildDevinSpawnOptions(input: {
	approvalMode: ApprovalModeId;
	cwd: string;
	env?: NodeJS.ProcessEnv;
}): AgentSpawnOptions {
	return {
		cmd: ["devin", "--permission-mode", devinPermissionMode(input.approvalMode), "acp"],
		cwd: input.cwd,
		env: input.env ?? process.env,
	};
}

export function buildOmpSpawnOptions(input: { cwd: string; env?: NodeJS.ProcessEnv }): AgentSpawnOptions {
	return { cmd: ["omp", "acp"], cwd: input.cwd, env: input.env ?? process.env };
}

export function isAcpMockEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
	return env.LEVEL5_USE_ACP_MOCK === USE_ACP_MOCK_VALUE;
}

export function selectedAgentBackend(env: NodeJS.ProcessEnv = process.env, provider: AcpProviderId = DEFAULT_ACP_PROVIDER): AgentBackendId {
	if (isAcpMockEnabled(env)) return "mock";
	return provider === "omp" ? "omp" : "devin";
}

export function defaultMockStatePath(): string {
	return resolve(homedir(), ".level5-build", "acp-mock-state.json");
}

export function resolveMockAcpStartPath(input: { env?: NodeJS.ProcessEnv; execPath?: string; cwd?: string } = {}): string {
	const env = input.env ?? process.env;
	const cwd = input.cwd ?? process.cwd();
	const execPath = input.execPath ?? process.execPath;
	const explicitPath = env.LEVEL5_ACP_MOCK_START_PATH ?? env.LEVEL5_ACP_MOCK_INDEX_PATH;
	if (explicitPath) {
		return explicitPath;
	}
	const candidates = [
		resolve(dirname(execPath), "../Resources/app/acp-mock-server/start.sh"),
		resolve(dirname(execPath), "Resources/app/acp-mock-server/start.sh"),
		resolve(cwd, "../acp-mock-server/start.sh"),
		resolve(cwd, "acp-mock-server/start.sh"),
	];

	return candidates.find((candidate) => existsSync(candidate)) ?? candidates[candidates.length - 1] ?? resolve("acp-mock-server/start.sh");
}

export function buildMockSpawnOptions(input: {
	cwd: string;
	env?: NodeJS.ProcessEnv;
	mockStartPath?: string;
}): AgentSpawnOptions {
	const mockStartPath = input.mockStartPath ?? resolveMockAcpStartPath({ env: input.env });
	const env = input.env ?? process.env;
	return {
		cmd: [mockStartPath],
		cwd: input.cwd,
		env: {
			...env,
			ACP_MOCK_STATE_PATH: env.ACP_MOCK_STATE_PATH ?? defaultMockStatePath(),
		},
	};
}

export function buildAgentSpawnOptions(input: {
	approvalMode: ApprovalModeId;
	cwd: string;
	env?: NodeJS.ProcessEnv;
	provider?: AcpProviderId;
}): AgentSpawnOptions {
	if (isAcpMockEnabled(input.env)) return buildMockSpawnOptions({ cwd: input.cwd, env: input.env });
	if (input.provider === "omp") return buildOmpSpawnOptions({ cwd: input.cwd, env: input.env });
	return buildDevinSpawnOptions(input);
}

export const AGENT_CLIENT_CAPABILITIES = {
	fs: { readTextFile: false, writeTextFile: false },
	terminal: false,
	auth: { terminal: false },
} as const;

export const DEVIN_MISSING_CLI_MESSAGE =
	"Devin CLI is not available. Install the Devin CLI, make sure `devin` is on PATH, and run `devin auth login` before starting an agent chat.";
export const OMP_MISSING_CLI_MESSAGE =
	"omp is not available. Install omp (curl -fsSL https://omp.sh/install | sh), make sure `omp` is on PATH, and run `omp` once interactively to sign in before starting an agent chat.";
export const ACP_MOCK_SPAWN_FAILURE_MESSAGE =
	"ACP mock backend is not available. Make sure acp-mock-server is present in the repository or bundled app resources.";

export function isDevinAvailable(env: NodeJS.ProcessEnv = process.env): boolean {
	const path = env.PATH ?? "";
	const pathExtensions = process.platform === "win32" ? (env.PATHEXT ?? ".EXE;.CMD;.BAT").split(";") : [""];
	return path
		.split(process.platform === "win32" ? ";" : ":")
		.filter(Boolean)
		.some((directory) =>
			pathExtensions.some((extension) => existsSync(resolve(directory, `devin${extension.toLowerCase()}`)) || existsSync(resolve(directory, `devin${extension}`))),
		);
}

export function isOmpAvailable(env: NodeJS.ProcessEnv = process.env): boolean {
	const path = env.PATH ?? "";
	const pathExtensions = process.platform === "win32" ? (env.PATHEXT ?? ".EXE;.CMD;.BAT").split(";") : [""];
	return path
		.split(process.platform === "win32" ? ";" : ":")
		.filter(Boolean)
		.some((directory) =>
			pathExtensions.some((extension) => existsSync(resolve(directory, `omp${extension.toLowerCase()}`)) || existsSync(resolve(directory, `omp${extension}`))),
		);
}

export function pickAutoApproveOptionId(options: AgentPermissionOption[]): string | undefined {
	return options.find(isAllowLikePermissionOption)?.optionId;
}

export function buildSelectedPermissionResponse(optionId: string): { outcome: { outcome: "selected"; optionId: string } } {
	return { outcome: { outcome: "selected", optionId } };
}

/**
 * Guards a backend's `session_info_update` notification against
 * persisting a session that only exists for warm-up (composer priming on
 * project selection, or the eager home-directory prime): those sessions
 * must stay invisible in the sidebar/DB until an actual send flips
 * `sessionPersisted` (see `persistCurrentSession` in `bun/index.ts`).
 * Some backends (the mock server's post-`session/new` timer, and
 * plausibly real Devin too) fire `session_info_update` unprompted right
 * after session creation, before any message was ever sent. The
 * `sessionId === currentSessionId` half of the guard is a separate,
 * equally necessary check: it drops a stale/late notification for a
 * session the connection has since closed or replaced (e.g. the user
 * switched projects, or a new session/new superseded it), so a
 * lagging notification can never write into the wrong session's row.
 */
export function shouldPersistSessionInfoUpdate(input: {
	sessionId: string;
	currentSessionId: string | null;
	sessionPersisted: boolean;
}): boolean {
	return input.sessionId === input.currentSessionId && input.sessionPersisted;
}

function isAllowLikePermissionOption(option: AgentPermissionOption): boolean {
	const values = [option.kind, option.name, option.optionId].filter((value): value is string => Boolean(value));
	return values.some((value) => {
		const normalized = value.toLowerCase().replace(/[\s-]+/g, "_");
		return normalized.startsWith("allow") || normalized.includes("_allow");
	});
}
