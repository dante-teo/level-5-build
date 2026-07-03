import type { RPCSchema } from "electrobun";

export type AgentModelId = string;
export type ApprovalModeId = "ask" | "auto" | "full-access";
export type AgentRunStatus = "idle" | "starting" | "running" | "stopping" | "completed" | "error";

export const APPROVAL_MODE_LABELS: Record<ApprovalModeId, string> = {
	ask: "Ask for approval",
	auto: "Approve for me",
	"full-access": "Full access",
};

export type AgentContentBlock =
	| { type: "text"; text: string }
	| { type: string; [key: string]: unknown };

export type AgentMessageUpdate = {
	kind: "message";
	role: "user" | "agent";
	messageId: string;
	content: AgentContentBlock;
};

export type AgentPlanItem = {
	title: string;
	priority?: string;
	status?: string;
};

export type AgentToolCall = {
	toolCallId: string;
	title: string;
	kind: string;
	status: string;
	content?: unknown[];
	locations?: unknown[];
	rawInput?: unknown;
};

export type AgentPermissionOption = {
	optionId: string;
	name: string;
	kind?: string;
};

export type AgentPermissionRequest = {
	requestId: number | string;
	sessionId: string;
	toolCall?: AgentToolCall;
	options: AgentPermissionOption[];
};

export type AgentConfigOption = {
	id: string;
	name?: string;
	currentValue?: string;
	options?: Array<{ value: string; name: string; description?: string }>;
};

export type AgentSessionSummary = {
	sessionId: string;
	title: string;
	cwd: string;
	isNoProject?: boolean;
	updatedAt: string;
	messageCount: number;
};

export type AgentSlashCommand = {
	name: string;
	description: string;
	hint?: string;
};

export type AgentSkill = {
	id: string;
	name: string;
	description: string;
};

export type AgentPromptAttachmentType = "file" | "directory";

export type AgentPromptAttachment = {
	type: AgentPromptAttachmentType;
	path: string;
	name: string;
};

export type AgentUsage = {
	used: number;
	size: number;
};

export type ProjectGitStatus =
	| {
			ok: true;
			root: string;
			branch: string;
			isDetached: boolean;
			changedFiles: number;
			additions: number;
			deletions: number;
			hasUntracked: boolean;
	  }
	| {
			ok: false;
			error?: string;
	  };

export type GetProjectGitStatusParams = {
	cwd: string;
};

export type AgentUpdate =
	| { kind: "status"; status: AgentRunStatus; sessionId?: string; cwd?: string }
	| AgentMessageUpdate
	| { kind: "plan"; items: AgentPlanItem[] }
	| { kind: "tool"; tool: AgentToolCall }
	| { kind: "permission"; request: AgentPermissionRequest }
	| { kind: "config"; options: AgentConfigOption[] }
	| { kind: "slashCommands"; commands: AgentSlashCommand[] }
	| { kind: "session"; session: AgentSessionSummary }
	| { kind: "usage"; used: number; size: number }
	| { kind: "stop"; stopReason: string }
	| { kind: "error"; message: string }
	| { kind: "info"; id: string; message: string };

export type StartAgentPromptParams = {
	prompt: string;
	cwd?: string | null;
	model?: AgentModelId | string;
	approvalMode?: ApprovalModeId | string;
	attachments?: AgentPromptAttachment[];
};

export type StartAgentPromptResponse = {
	accepted: boolean;
	sessionId?: string;
};

export type PrepareAgentSessionParams = {
	cwd?: string | null;
	approvalMode?: ApprovalModeId | string;
};

export type PrepareAgentSessionResponse = {
	prepared: boolean;
	sessionId?: string;
	reason?: string;
};

export type RespondToAgentPermissionParams = {
	requestId: number | string;
	optionId: string;
};

export type LoadAgentSessionParams = {
	sessionId: string;
};

export type LoadAgentSessionResponse = {
	loaded: boolean;
	reason?: string;
};

export type DeleteAgentSessionParams = {
	sessionId: string;
};

export type DeleteAgentSessionResponse = {
	deleted: boolean;
	reason?: string;
};

export type AppRPC = {
	// functions that execute in the main (bun) process, callable from the webview
	bun: RPCSchema<{
		requests: {
			toggleMaximizeWindow: {
				params: void;
				response: boolean;
			};
			selectProjectFolder: {
				params: void;
				response: string | null;
			};
			selectAttachmentFile: {
				params: void;
				response: string | null;
			};
			selectAttachmentFolder: {
				params: void;
				response: string | null;
			};
			startAgentPrompt: {
				params: StartAgentPromptParams;
				response: StartAgentPromptResponse;
			};
			prepareAgentSession: {
				params: PrepareAgentSessionParams;
				response: PrepareAgentSessionResponse;
			};
			cancelAgentPrompt: {
				params: void;
				response: boolean;
			};
			respondToAgentPermission: {
				params: RespondToAgentPermissionParams;
				response: boolean;
			};
			listAgentSessions: {
				params: void;
				response: AgentSessionSummary[];
			};
			listAgentSlashCommands: {
				params: void;
				response: AgentSlashCommand[];
			};
			listAgentSkills: {
				params: void;
				response: AgentSkill[];
			};
			loadAgentSession: {
				params: LoadAgentSessionParams;
				response: LoadAgentSessionResponse;
			};
			deleteAgentSession: {
				params: DeleteAgentSessionParams;
				response: DeleteAgentSessionResponse;
			};
			startNewAgentChat: {
				params: void;
				response: boolean;
			};
			resetAgentChat: {
				params: void;
				response: boolean;
			};
			getProjectGitStatus: {
				params: GetProjectGitStatusParams;
				response: ProjectGitStatus;
			};
		};
	}>;
	webview: RPCSchema<{
		messages: {
			agentUpdate: AgentUpdate;
		};
	}>;
};
