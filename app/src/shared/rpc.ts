import type { RPCSchema } from "electrobun";

export type AgentModelId = string;
export type ApprovalModeId = "ask" | "auto" | "full-access";
export type AcpProviderId = "devin" | "omp";
export type AgentRunStatus = "idle" | "starting" | "running" | "stopping" | "completed" | "error";

export const APPROVAL_MODE_LABELS: Record<ApprovalModeId, string> = {
	ask: "Ask for approval",
	auto: "Approve for me",
	"full-access": "Full access",
};

export const ACP_PROVIDER_LABELS: Record<AcpProviderId, string> = {
	devin: "Devin",
	omp: "Oh My Pi (omp)",
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

export type AgentThoughtUpdate = {
	kind: "thought";
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

// Mirrors app/Sources/Level5Core/RecentProjectStore.swift's RecentProject:
// a durable, independently-tracked (not derived from session history), 10
// most-recently-opened-folder-capped list. See AGENTS.md.
export type RecentProjectSummary = {
	path: string;
	displayName: string;
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

// Review is Git working-tree based and inspect-only: it never stages,
// discards, commits, reverts, or answers permissions. Mirrors
// app/Sources/Level5Core/ProjectReview.swift's shape so both clients agree
// on the same review contract.

export type ChangeKind =
	| "added"
	| "modified"
	| "deleted"
	| "renamed"
	| "copied"
	| "untracked"
	| "typeChanged"
	| "unknown";

export type ContentKind = "text" | "image" | "binary" | "submodule" | "symlink" | "unknown";

export type ProjectChangedFile = {
	path: string;
	oldPath?: string;
	indexStatus: string;
	workingTreeStatus: string;
	changeKind: ChangeKind;
	contentKind: ContentKind;
	additions: number;
	deletions: number;
	byteSize?: number;
};

export type ProjectReviewError = {
	message: string;
	rawOutput?: string;
};

export type ProjectReviewSnapshot =
	| {
			isAvailable: true;
			root: string;
			branch: string | null;
			isDetached: boolean;
			files: ProjectChangedFile[];
			totalChangedFiles: number;
			overflowCount: number;
	  }
	| {
			isAvailable: false;
			error: ProjectReviewError;
	  };

export type ProjectFilePreviewContent =
	| { kind: "unifiedDiff"; diff: string }
	| { kind: "image"; path: string; byteSize?: number }
	| { kind: "metadata"; message: string }
	| { kind: "tooLarge"; byteSize: number; limit: number }
	| { kind: "error"; error: ProjectReviewError };

export type ProjectFilePreview = {
	file: ProjectChangedFile;
	content: ProjectFilePreviewContent;
};

export type GetProjectReviewSnapshotParams = {
	cwd: string;
};

export type GetFileDiffPreviewParams = {
	cwd: string;
	file: ProjectChangedFile;
};

export type AgentUpdate =
	| { kind: "status"; status: AgentRunStatus; sessionId?: string; cwd?: string }
	| AgentMessageUpdate
	| AgentThoughtUpdate
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

/**
 * Wraps every pushed AgentUpdate with the session it belongs to. Required
 * once each project runs its own concurrent agent process/turn (see
 * AGENTS.md per-project process pool notes): without an explicit origin,
 * the renderer could not tell two concurrently-running projects' updates
 * apart and could merge one project's content into another's transcript.
 */
export type AgentUpdateMessage = {
	sessionId: string;
	update: AgentUpdate;
};

export type StartAgentPromptParams = {
	prompt: string;
	cwd?: string | null;
	model?: AgentModelId | string;
	approvalMode?: ApprovalModeId | string;
	attachments?: AgentPromptAttachment[];
	// Set when continuing an already-known session (selected from the
	// sidebar). Selecting a session is pure local retrieval and never talks
	// to the agent runtime; the first send into it is what triggers
	// send-time session/load priming (see AGENTS.md).
	sessionId?: string;
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
	// Which project's connection this request belongs to, so the backend can
	// route the response correctly now that each project runs its own
	// concurrent agent process (see AGENTS.md per-project process pool notes).
	sessionId: string;
};

export type CancelAgentPromptParams = {
	sessionId: string;
};

export type GetSessionTranscriptParams = {
	sessionId: string;
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
				params: CancelAgentPromptParams;
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
			listRecentProjects: {
				params: void;
				response: RecentProjectSummary[];
			};
			getAcpProvider: {
				params: void;
				response: AcpProviderId;
			};
			setAcpProvider: {
				params: { provider: AcpProviderId };
				response: boolean;
			};
			listAgentSlashCommands: {
				params: void;
				response: AgentSlashCommand[];
			};
			listAgentConfigOptions: {
				params: void;
				response: AgentConfigOption[];
			};
			listAgentSkills: {
				params: void;
				response: AgentSkill[];
			};
			getSessionTranscript: {
				params: GetSessionTranscriptParams;
				response: AgentUpdate[];
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
			getProjectReviewSnapshot: {
				params: GetProjectReviewSnapshotParams;
				response: ProjectReviewSnapshot;
			};
			getFileDiffPreview: {
				params: GetFileDiffPreviewParams;
				response: ProjectFilePreview;
			};
		};
	}>;
	webview: RPCSchema<{
		messages: {
			agentUpdate: AgentUpdateMessage;
		};
	}>;
};
