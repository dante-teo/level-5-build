import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import type { ApprovalModeId, AgentPermissionOption } from "../../shared/rpc";

export type AgentPermissionMode = "normal" | "bypass";

export type AgentSpawnOptions = {
	cmd: string[];
	cwd: string;
	env: NodeJS.ProcessEnv;
};

export const DEFAULT_APPROVAL_MODE: ApprovalModeId = "ask";

const APPROVAL_MODES = new Set<ApprovalModeId>(["ask", "auto", "full-access"]);

export function normalizeApprovalMode(mode: string | undefined): ApprovalModeId {
	return APPROVAL_MODES.has(mode as ApprovalModeId) ? (mode as ApprovalModeId) : DEFAULT_APPROVAL_MODE;
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

export const AGENT_CLIENT_CAPABILITIES = {
	fs: { readTextFile: false, writeTextFile: false },
	terminal: false,
	auth: { terminal: false },
} as const;

export const DEVIN_MISSING_CLI_MESSAGE =
	"Devin CLI is not available. Install the Devin CLI, make sure `devin` is on PATH, and run `devin auth login` before starting an agent chat.";

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

export function pickAutoApproveOptionId(options: AgentPermissionOption[]): string | undefined {
	return options.find(isAllowLikePermissionOption)?.optionId;
}

export function buildSelectedPermissionResponse(optionId: string): { outcome: { outcome: "selected"; optionId: string } } {
	return { outcome: { outcome: "selected", optionId } };
}

function isAllowLikePermissionOption(option: AgentPermissionOption): boolean {
	const values = [option.kind, option.name, option.optionId].filter((value): value is string => Boolean(value));
	return values.some((value) => {
		const normalized = value.toLowerCase().replace(/[\s-]+/g, "_");
		return normalized.startsWith("allow") || normalized.includes("_allow");
	});
}
