import type { RPCSchema } from "electrobun";

export type MockModelId = "mock-fast" | "mock-pro" | "mock-deep";
export type ApprovalModeId = "ask" | "architect" | "code" | "auto";
export type MockRunStatus = "idle" | "starting" | "running" | "completed" | "error";

export type MockContentBlock =
	| { type: "text"; text: string }
	| { type: string; [key: string]: unknown };

export type MockMessageUpdate = {
	kind: "message";
	role: "user" | "agent";
	messageId: string;
	content: MockContentBlock;
};

export type MockPlanItem = {
	title: string;
	priority?: string;
	status?: string;
};

export type MockToolCall = {
	toolCallId: string;
	title: string;
	kind: string;
	status: string;
	content?: unknown[];
	locations?: unknown[];
	rawInput?: unknown;
};

export type MockPermissionOption = {
	optionId: string;
	name: string;
	kind?: string;
};

export type MockPermissionRequest = {
	requestId: number | string;
	sessionId: string;
	toolCall?: MockToolCall;
	options: MockPermissionOption[];
};

export type MockConfigOption = {
	id: string;
	name?: string;
	currentValue?: string;
	options?: Array<{ value: string; name: string; description?: string }>;
};

export type MockSessionSummary = {
	sessionId: string;
	title: string;
	cwd: string;
	updatedAt: string;
	messageCount: number;
};

export type MockAgentUpdate =
	| { kind: "status"; status: MockRunStatus; sessionId?: string; cwd?: string }
	| MockMessageUpdate
	| { kind: "plan"; items: MockPlanItem[] }
	| { kind: "tool"; tool: MockToolCall }
	| { kind: "permission"; request: MockPermissionRequest }
	| { kind: "config"; options: MockConfigOption[] }
	| { kind: "session"; session: MockSessionSummary }
	| { kind: "stop"; stopReason: string }
	| { kind: "error"; message: string };

export type StartMockPromptParams = {
	prompt: string;
	cwd?: string | null;
	model?: MockModelId | string;
	approvalMode?: ApprovalModeId | string;
};

export type StartMockPromptResponse = {
	accepted: boolean;
	sessionId?: string;
};

export type RespondToMockPermissionParams = {
	requestId: number | string;
	optionId: string;
};

export type LoadMockSessionParams = {
	sessionId: string;
};

export type LoadMockSessionResponse = {
	loaded: boolean;
	reason?: string;
};

export type DeleteMockSessionParams = {
	sessionId: string;
};

export type DeleteMockSessionResponse = {
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
			startMockPrompt: {
				params: StartMockPromptParams;
				response: StartMockPromptResponse;
			};
			respondToMockPermission: {
				params: RespondToMockPermissionParams;
				response: boolean;
			};
			listMockSessions: {
				params: void;
				response: MockSessionSummary[];
			};
			loadMockSession: {
				params: LoadMockSessionParams;
				response: LoadMockSessionResponse;
			};
			deleteMockSession: {
				params: DeleteMockSessionParams;
				response: DeleteMockSessionResponse;
			};
			startNewMockChat: {
				params: void;
				response: boolean;
			};
			resetMockChat: {
				params: void;
				response: boolean;
			};
		};
	}>;
	webview: RPCSchema<{
		messages: {
			mockAgentUpdate: MockAgentUpdate;
		};
	}>;
};
