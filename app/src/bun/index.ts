import { homedir } from "node:os";
import { ApplicationMenu, BrowserWindow, BrowserView, Updater, Utils } from "electrobun/bun";
import { AcpClient } from "./acp/client";
import { AcpError } from "./acp/errors";
import { CLIENT_METHODS } from "./acp/schema";
import {
	AcpJsonRpcTransport,
	type AcpNotification,
	type AcpServerRequest,
	type JsonObject,
	type JsonValue,
	type RpcId,
} from "./acp/transport";
import { startAcpTurnIdleWatchdog, type AcpTurnIdleWatchdog } from "./acp/watchdog";
import {
	AGENT_CLIENT_CAPABILITIES,
	ACP_MOCK_SPAWN_FAILURE_MESSAGE,
	DEFAULT_APPROVAL_MODE,
	DEVIN_MISSING_CLI_MESSAGE,
	buildAgentSpawnOptions,
	buildSelectedPermissionResponse,
	devinPermissionMode,
	isDevinAvailable,
	selectedAgentBackend,
	normalizeApprovalMode,
	pickAutoApproveOptionId,
	resolveAgentCwd,
} from "./agent/runtime";
import { getProjectGitStatus } from "./git/status";
import { APPROVAL_MODE_LABELS } from "../shared/rpc";
import type {
	AppRPC,
	ApprovalModeId,
	DeleteAgentSessionParams,
	GetProjectGitStatusParams,
	DeleteAgentSessionResponse,
	LoadAgentSessionParams,
	LoadAgentSessionResponse,
	AgentUpdate,
	AgentConfigOption,
	AgentContentBlock,
	AgentPermissionOption,
	AgentPermissionRequest,
	AgentPlanItem,
	AgentPromptAttachment,
	AgentSessionSummary,
	AgentSkill,
	AgentSlashCommand,
	AgentToolCall,
	PrepareAgentSessionParams,
	PrepareAgentSessionResponse,
	RespondToAgentPermissionParams,
	StartAgentPromptParams,
	StartAgentPromptResponse,
} from "../shared/rpc";

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;
const ACP_TURN_IDLE_TIMEOUT_MS = Number(process.env.LEVEL5_ACP_TURN_IDLE_TIMEOUT_MS ?? "120000");
const ACP_TURN_IDLE_CHECK_INTERVAL_MS = 2_000;

// Check if Vite dev server is running for HMR
async function getMainViewUrl(): Promise<string> {
	const channel = await Updater.localInfo.channel();
	if (channel === "dev") {
		try {
			await fetch(DEV_SERVER_URL, { method: "HEAD" });
			console.log(`HMR enabled: Using Vite dev server at ${DEV_SERVER_URL}`);
			return DEV_SERVER_URL;
		} catch {
			console.log(
				"Vite dev server not running. Run 'bun run dev:hmr' for HMR support.",
			);
		}
	}
	return "views://mainview/index.html";
}

// Create the main application window
const url = await getMainViewUrl();

// Electrobun's custom window drag doesn't hook into the OS's native move loop,
// so dragging to the screen edges/top won't auto-tile like a normal mac window.
// As a stand-in for that, let the webview double-click the drag region to
// toggle maximize/fill-screen (mirrors the native macOS title bar convention).
let mainWindow: BrowserWindow;
let agentClient: AgentAcpClient | null = null;

function sendAgentUpdate(update: AgentUpdate) {
	rpc.send.agentUpdate(update);
}

function asObject(value: unknown): JsonObject {
	if (!value || typeof value !== "object" || Array.isArray(value)) {
		return {};
	}
	return value as JsonObject;
}

function asString(value: unknown, fallback = ""): string {
	return typeof value === "string" ? value : fallback;
}

function asOptionalString(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

function asNumber(value: unknown, fallback = 0): number {
	return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

class AgentAcpClient {
	private process: Bun.PipedSubprocess | null = null;
	private stdin: Bun.PipedSubprocess["stdin"] | null = null;
	private transport: AcpJsonRpcTransport | null = null;
	private acp: AcpClient | null = null;
	private readonly permissionRequests = new Map<RpcId, AgentPermissionRequest>();
	private readonly sessions = new Map<string, AgentSessionSummary>();
	private readonly transcripts = new Map<string, AgentUpdate[]>();
	private turnWatchdog: AcpTurnIdleWatchdog | null = null;
	private initialized = false;
	private sessionId: string | null = null;
	private currentCwd: string | null = null;
	private processCwd: string | null = null;
	private processPermissionMode: string | null = null;
	private running = false;
	private cancellationRequested = false;
	private approvalMode: ApprovalModeId = DEFAULT_APPROVAL_MODE;
	private configOptions: AgentConfigOption[] = [];
	private slashCommands: AgentSlashCommand[] = [];

	constructor(private readonly emit: (update: AgentUpdate) => void) {}

	get isRunning() {
		return this.running;
	}

	async startPrompt(params: StartAgentPromptParams): Promise<void> {
		if (this.running) {
			this.emit({ kind: "error", message: "An agent turn is already running." });
			return;
		}

		this.running = true;
		this.cancellationRequested = false;
		const cwd = resolveAgentCwd(params.cwd);
		this.approvalMode = normalizeApprovalMode(params.approvalMode);
		this.emit({ kind: "status", status: "starting", cwd, sessionId: this.sessionId ?? undefined });

		try {
			await this.ensureProcess(cwd);
			await this.ensureInitialized();
			await this.ensureSession(cwd);
			if (!this.sessionId) {
				throw new Error("Agent session was not created.");
			}

			if (params.model && this.configOptions.some((option) => option.id === "model")) {
				await this.requireAcp().setConfigOption({
					sessionId: this.sessionId,
					configId: "model",
					value: params.model,
				});
			}

			this.emit({ kind: "status", status: "running", cwd, sessionId: this.sessionId });
			this.startTurnWatchdog();
			const result = asObject(
				await this.requireAcp().prompt({
					sessionId: this.sessionId,
					prompt: buildPromptContent(params.prompt, params.attachments),
				}),
			);
			if (this.cancellationRequested) {
				this.emit({ kind: "stop", stopReason: "cancelled" });
				this.emit({ kind: "status", status: "completed", cwd, sessionId: this.sessionId });
				return;
			}
			const existingSession = this.sessions.get(this.sessionId);
			if (existingSession) {
				this.rememberSession({
					...existingSession,
					updatedAt: new Date().toISOString(),
					messageCount: existingSession.messageCount + 1,
				});
			}
			this.emit({ kind: "stop", stopReason: asString(result.stopReason, "end_turn") });
			this.emit({ kind: "status", status: "completed", cwd, sessionId: this.sessionId });
		} catch (error) {
			if (this.cancellationRequested) {
				this.emit({ kind: "stop", stopReason: "cancelled" });
				this.emit({ kind: "status", status: "completed", cwd, sessionId: this.sessionId ?? undefined });
				return;
			}
			this.emit({
				kind: "error",
				message: error instanceof Error ? error.message : "Agent request failed.",
			});
			this.emit({ kind: "status", status: "error", cwd, sessionId: this.sessionId ?? undefined });
		} finally {
			this.stopTurnWatchdog();
			this.running = false;
		}
	}

	cancelActiveTurn(): boolean {
		if (!this.running || !this.sessionId) {
			return false;
		}
		this.cancellationRequested = true;
		this.turnWatchdog?.setAwaitingHuman(false);
		this.turnWatchdog?.touch();
		this.requireAcp().cancel({ sessionId: this.sessionId });
		for (const requestId of this.permissionRequests.keys()) {
			this.requireAcp().respondSuccess(requestId, { outcome: { outcome: "cancelled" } });
		}
		this.permissionRequests.clear();
		this.emit({ kind: "status", status: "stopping", cwd: this.currentCwd ?? undefined, sessionId: this.sessionId });
		return true;
	}

	respondToPermission({ requestId, optionId }: RespondToAgentPermissionParams): boolean {
		if (!this.permissionRequests.has(requestId)) {
			return false;
		}
		this.permissionRequests.delete(requestId);
		this.turnWatchdog?.setAwaitingHuman(false);
		this.turnWatchdog?.touch();
		this.requireAcp().respondSuccess(requestId, buildSelectedPermissionResponse(optionId));
		return true;
	}

	async listSessions(): Promise<AgentSessionSummary[]> {
		if (!this.process) {
			return this.sortedSessions();
		}
		await this.ensureInitialized();
		let cursor: string | undefined;
		do {
			const result = asObject(
				await this.requireAcp().listSessions(cursor ? { cursor } : undefined),
			);
			this.emitConfig(result.configOptions);
			const sessionValues = Array.isArray(result.sessions) ? result.sessions : [];
			for (const sessionValue of sessionValues) {
				this.rememberSession(normalizeSessionSummary(sessionValue), false);
			}
			cursor = asOptionalString(result.nextCursor);
		} while (cursor);

		return this.sortedSessions();
	}

	async listSlashCommands(): Promise<AgentSlashCommand[]> {
		return this.slashCommands;
	}

	async listSkills(): Promise<AgentSkill[]> {
		return [];
	}

	async prepareSession(params: PrepareAgentSessionParams): Promise<PrepareAgentSessionResponse> {
		if (this.running) {
			return { prepared: false, reason: "Wait for the active agent turn to finish before switching projects." };
		}
		const cwd = resolveAgentCwd(params.cwd);
		this.approvalMode = normalizeApprovalMode(params.approvalMode);
		try {
			await this.ensureProcess(cwd);
			await this.ensureInitialized();
			await this.ensureSession(cwd);
			this.emit({ kind: "status", status: "idle", cwd, sessionId: this.sessionId ?? undefined });
			return { prepared: true, sessionId: this.sessionId ?? undefined };
		} catch (error) {
			return { prepared: false, reason: error instanceof Error ? error.message : "Failed to prepare agent session." };
		}
	}

	async loadSession({ sessionId }: LoadAgentSessionParams): Promise<LoadAgentSessionResponse> {
		if (this.running) {
			return { loaded: false, reason: "An agent turn is already running." };
		}
		if (!sessionId) {
			return { loaded: false, reason: "No session was selected." };
		}

		try {
			const session = this.sessions.get(sessionId);
			if (!session) {
				return { loaded: false, reason: "That chat no longer exists." };
			}

			await this.ensureProcess(session.cwd);
			await this.ensureInitialized();
			this.permissionRequests.clear();
			const cachedTranscript = this.transcripts.get(sessionId);
			const acp = this.requireAcp();
			const sessionParams = {
				sessionId,
				cwd: session.cwd,
				mcpServers: [],
			};
			const result = asObject(
				await (cachedTranscript ? acp.resumeSession(sessionParams) : acp.loadSession(sessionParams)),
			);
			this.sessionId = sessionId;
			this.currentCwd = session.cwd;
			this.rememberSession(session);
			this.emit({ kind: "status", status: "idle", sessionId, cwd: session.cwd });
			this.emitConfig(result.configOptions);
			if (cachedTranscript) {
				this.replayTranscript(sessionId);
			}
			return { loaded: true };
		} catch (error) {
			return { loaded: false, reason: error instanceof Error ? error.message : "Failed to load chat." };
		}
	}

	async deleteSession({ sessionId }: DeleteAgentSessionParams): Promise<DeleteAgentSessionResponse> {
		if (!sessionId) {
			return { deleted: false, reason: "No session was selected." };
		}
		if (this.running && sessionId === this.sessionId) {
			return { deleted: false, reason: "Wait for the active agent turn to finish before deleting this chat." };
		}

		try {
			await this.ensureProcess(this.sessions.get(sessionId)?.cwd ?? this.currentCwd ?? homedir());
			await this.ensureInitialized();
			await this.requireAcp().deleteSession({ sessionId });
			this.permissionRequests.clear();
			this.sessions.delete(sessionId);
			this.transcripts.delete(sessionId);
			if (sessionId === this.sessionId) {
				this.sessionId = null;
				this.currentCwd = null;
				this.emit({ kind: "status", status: "idle" });
			}
			return { deleted: true };
		} catch (error) {
			return { deleted: false, reason: error instanceof Error ? error.message : "Failed to delete chat." };
		}
	}

	async startNewChat(): Promise<boolean> {
		if (this.running) {
			return false;
		}
		this.permissionRequests.clear();
		if (this.sessionId) {
			await this.requireAcp().closeSession({ sessionId: this.sessionId }).catch(() => undefined);
		}
		this.sessionId = null;
		this.currentCwd = null;
		this.emit({ kind: "status", status: "idle" });
		return true;
	}

	async reset(): Promise<void> {
		this.running = false;
		this.stopTurnWatchdog();
		this.transport?.failAll(new AcpError("transport_failure", "Agent ACP client reset."));
		this.permissionRequests.clear();
		this.stdin?.end();
		this.stdin = null;
		this.process?.kill();
		this.process = null;
		this.transport = null;
		this.acp = null;
		this.initialized = false;
		this.sessionId = null;
		this.currentCwd = null;
		this.processCwd = null;
		this.processPermissionMode = null;
		this.cancellationRequested = false;
		this.approvalMode = DEFAULT_APPROVAL_MODE;
		this.configOptions = [];
		this.slashCommands = [];
		this.sessions.clear();
		this.transcripts.clear();
		this.emit({ kind: "status", status: "idle" });
	}

	private async ensureProcess(cwd: string): Promise<void> {
		const backend = selectedAgentBackend();
		const permissionMode = backend === "mock" ? "mock" : devinPermissionMode(this.approvalMode);
		const spawnFailureMessage = backend === "mock" ? ACP_MOCK_SPAWN_FAILURE_MESSAGE : DEVIN_MISSING_CLI_MESSAGE;
		if (this.process) {
			if (this.processCwd === cwd && this.processPermissionMode === permissionMode) {
				return;
			}
			const approvalMode = this.approvalMode;
			await this.reset();
			this.approvalMode = approvalMode;
		}

		try {
			if (backend === "devin" && !isDevinAvailable()) {
				throw new AcpError("spawn_failure", DEVIN_MISSING_CLI_MESSAGE);
			}
			const options = buildAgentSpawnOptions({ approvalMode: this.approvalMode, cwd });
			const subprocess = Bun.spawn({
				...options,
				stdin: "pipe",
				stdout: "pipe",
				stderr: "pipe",
			});
			this.process = subprocess;
			this.processCwd = cwd;
			this.processPermissionMode = permissionMode;
			this.stdin = subprocess.stdin;
		} catch (error) {
			if (error instanceof AcpError) {
				throw error;
			}
			throw new AcpError("spawn_failure", spawnFailureMessage);
		}

		if (!this.process || !this.stdin) {
			return;
		}
		this.transport = new AcpJsonRpcTransport({
			writeLine: (line) => {
				if (!this.stdin) {
					throw new AcpError("transport_failure", "Agent ACP process is not running.");
				}
				this.stdin.write(`${line}\n`);
			},
			onServerRequest: (request) => this.handleServerRequest(request),
			onNotification: (notification) => this.handleNotification(notification),
			onDiagnostic: ({ error }) => {
				if (error.code === "transport_failure") {
					this.emit({ kind: "error", message: error.message });
				}
			},
			onActivity: () => this.turnWatchdog?.touch(),
		});
		this.acp = new AcpClient(this.transport);
		void this.readStdout(this.process.stdout);
		void this.readStderr(this.process.stderr);
		void this.watchExit(this.process);
	}

	private async ensureInitialized(): Promise<void> {
		if (this.initialized) {
			return;
		}

		const result = asObject(
			await this.requireAcp().initialize({
				protocolVersion: 1,
				clientInfo: { name: "level5-build", version: "0.0.0" },
				clientCapabilities: AGENT_CLIENT_CAPABILITIES,
			}),
		);
		this.emitConfig(result.configOptions);
		this.initialized = true;
	}

	private async ensureSession(cwd: string): Promise<void> {
		if (this.sessionId && this.currentCwd === cwd) {
			return;
		}
		if (this.sessionId && this.currentCwd !== cwd) {
			await this.requireAcp().closeSession({ sessionId: this.sessionId }).catch(() => undefined);
			this.sessionId = null;
			this.currentCwd = null;
		}

		const result = asObject(
			await this.requireAcp().createSession({
				cwd,
				mcpServers: [],
			}),
		);
		const sessionId = asString(result.sessionId);
		if (!sessionId) {
			throw new Error("Agent ACP process did not return a session id.");
		}
		this.sessionId = sessionId;
		this.currentCwd = cwd;
		this.rememberSession({
			sessionId,
			title: "New chat",
			cwd,
			updatedAt: new Date().toISOString(),
			messageCount: 0,
		});
		this.emit({ kind: "status", status: "starting", sessionId, cwd });
		this.emitConfig(result.configOptions);
	}

	private rememberSession(session: AgentSessionSummary, shouldEmit = true): AgentSessionSummary {
		const existing = this.sessions.get(session.sessionId);
		const nextSession = {
			...existing,
			...session,
			title: session.title.trim() || existing?.title || "New chat",
			cwd: session.cwd || existing?.cwd || this.currentCwd || homedir(),
			updatedAt: session.updatedAt || existing?.updatedAt || new Date().toISOString(),
			messageCount: session.messageCount || existing?.messageCount || 0,
		};
		this.sessions.set(session.sessionId, nextSession);
		if (shouldEmit) {
			this.emit({ kind: "session", session: nextSession });
		}
		return nextSession;
	}

	private sortedSessions(): AgentSessionSummary[] {
		return [...this.sessions.values()].sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
	}

	private rememberTranscriptUpdate(sessionId: string, update: AgentUpdate): void {
		if (!sessionId) {
			return;
		}
		const current = this.transcripts.get(sessionId) ?? [];
		this.transcripts.set(sessionId, upsertTranscriptUpdate(current, update));
	}

	private emitTranscriptUpdate(sessionId: string, update: AgentUpdate): void {
		this.rememberTranscriptUpdate(sessionId, update);
		this.emit(update);
	}

	private replayTranscript(sessionId: string): void {
		const transcript = this.transcripts.get(sessionId);
		if (!transcript) {
			return;
		}
		for (const update of transcript) {
			this.emit(update);
		}
	}

	private startTurnWatchdog(): void {
		this.stopTurnWatchdog();
		this.turnWatchdog = startAcpTurnIdleWatchdog({
			idleTimeoutMs: Number.isFinite(ACP_TURN_IDLE_TIMEOUT_MS) && ACP_TURN_IDLE_TIMEOUT_MS > 0 ? ACP_TURN_IDLE_TIMEOUT_MS : 120_000,
			checkIntervalMs: ACP_TURN_IDLE_CHECK_INTERVAL_MS,
			isTurnActive: () => this.running,
			onIdleTimeout: (idleMs) => {
				const error = new AcpError("request_timeout", `Agent turn went silent for ${Math.round(idleMs / 1000)}s.`);
				this.forceStopActiveTurn(error);
			},
		});
	}

	private stopTurnWatchdog(): void {
		this.turnWatchdog?.stop();
		this.turnWatchdog = null;
	}

	private requireAcp(): AcpClient {
		if (!this.acp) {
			throw new AcpError("transport_failure", "Agent ACP process is not running.");
		}
		return this.acp;
	}

	private forceStopActiveTurn(error: AcpError): void {
		const sessionId = this.sessionId;
		if (sessionId) {
			try {
				this.acp?.cancel({ sessionId });
			} catch {
				// The timeout path is already failing the transport; best-effort cancel only.
			}
		}
		for (const requestId of this.permissionRequests.keys()) {
			try {
				this.acp?.respondSuccess(requestId, { outcome: { outcome: "cancelled" } });
			} catch {
				// The process may already be wedged or gone; reset below fences off stale work.
			}
		}
		this.permissionRequests.clear();
		this.transport?.failAll(error);
		this.stopTurnWatchdog();
		this.running = false;
		this.initialized = false;
		this.sessionId = null;
		this.currentCwd = null;
		this.acp = null;
		this.stdin?.end();
		this.stdin = null;
		this.process?.kill();
		this.process = null;
		this.transport = null;
	}

	private async readStdout(stdout: ReadableStream<Uint8Array>): Promise<void> {
		const reader = stdout.getReader();
		const decoder = new TextDecoder();
		try {
			while (true) {
				const { done, value } = await reader.read();
				if (done) break;
				this.transport?.receiveChunk(decoder.decode(value, { stream: true }));
			}
		} catch (error) {
			this.emit({
				kind: "error",
				message: error instanceof Error ? error.message : "Failed to read agent ACP stdout.",
			});
		} finally {
			const rest = decoder.decode();
			if (rest) {
				this.transport?.receiveChunk(rest);
			}
		}
	}

	private handleServerRequest(message: AcpServerRequest): void {
		if (!AcpClient.isPermissionRequest(message)) {
			this.requireAcp().respondMethodNotFound(message);
			return;
		}

		const params = asObject(message.params);
		const options: AgentPermissionOption[] = Array.isArray(params.options)
			? params.options.map((option) => {
					const object = asObject(option);
					return {
						optionId: asString(object.optionId),
						name: asString(object.name, asString(object.optionId)),
						kind: asOptionalString(object.kind),
					};
				})
			: [];
		const toolCall = normalizeToolCall(params.toolCall);

		if (this.approvalMode !== "ask") {
			const autoOptionId = pickAutoApproveOptionId(options);
			if (autoOptionId) {
				this.requireAcp().respondSuccess(message.id, buildSelectedPermissionResponse(autoOptionId));
				this.emit({
					kind: "info",
					id: String(message.id),
					message: `Auto-approved "${toolCall.title}" (${APPROVAL_MODE_LABELS[this.approvalMode]} mode).`,
				});
				return;
			}
		}

		const request: AgentPermissionRequest = {
			requestId: message.id ?? "",
			sessionId: asString(params.sessionId, this.sessionId ?? ""),
			toolCall,
			options,
		};
		this.permissionRequests.set(message.id, request);
		this.turnWatchdog?.setAwaitingHuman(true);
		this.emit({ kind: "permission", request });
	}

	private handleNotification(message: AcpNotification): void {
		if (message.method !== CLIENT_METHODS.session_update) {
			return;
		}
		const params = asObject(message.params);
		const update = asObject(params.update);
		const updateType = asString(update.sessionUpdate);
		const sessionId = asString(params.sessionId, this.sessionId ?? "");

		if (updateType === "user_message_chunk" || updateType === "agent_message_chunk") {
			this.emitTranscriptUpdate(sessionId, {
				kind: "message",
				role: updateType === "user_message_chunk" ? "user" : "agent",
				messageId: asString(update.messageId),
				content: normalizeContent(update.content),
			});
			return;
		}
		if (updateType === "plan") {
			this.emitTranscriptUpdate(sessionId, {
				kind: "plan",
				items: Array.isArray(update.entries) ? update.entries.map(normalizePlanItem) : [],
			});
			return;
		}
		if (updateType === "tool_call") {
			this.emitTranscriptUpdate(sessionId, { kind: "tool", tool: normalizeToolCall(update, { isUpdate: false }) });
			return;
		}
		if (updateType === "tool_call_update") {
			this.emitTranscriptUpdate(sessionId, { kind: "tool", tool: normalizeToolCall(update, { isUpdate: true }) });
			return;
		}
		if (updateType === "config_option_update") {
			this.emitConfig(update.configOptions);
			return;
		}
		if (updateType === "available_commands_update") {
			this.slashCommands = Array.isArray(update.availableCommands)
				? update.availableCommands.map(normalizeSlashCommand)
				: [];
			this.emit({ kind: "slashCommands", commands: this.slashCommands });
			return;
		}
		if (updateType === "usage_update") {
			this.emitTranscriptUpdate(sessionId, {
				kind: "usage",
				used: asNumber(update.used),
				size: asNumber(update.size, 1),
			});
			return;
		}
		if (updateType === "session_info_update") {
			this.rememberSession(
				normalizeSessionSummary({
					sessionId,
					cwd: this.currentCwd ?? "",
					title: update.title,
					updatedAt: update.updatedAt,
					_meta: update._meta,
				}),
			);
		}
	}

	private emitConfig(value: JsonValue | undefined): void {
		if (!Array.isArray(value)) {
			return;
		}
		const options = value.map((entry) => {
			const object = asObject(entry);
			return {
				id: asString(object.id),
				name: asOptionalString(object.name),
				currentValue: asOptionalString(object.currentValue),
				options: Array.isArray(object.options)
					? object.options.map((option) => {
							const optionObject = asObject(option);
							return {
								value: asString(optionObject.value),
								name: asString(optionObject.name),
								description: asOptionalString(optionObject.description),
							};
						})
					: undefined,
			} satisfies AgentConfigOption;
		});
		this.configOptions = options;
		this.emit({
			kind: "config",
			options,
		});
	}

	private async readStderr(stderr: ReadableStream<Uint8Array>): Promise<void> {
		const reader = stderr.getReader();
		const decoder = new TextDecoder();
		while (true) {
			const { done, value } = await reader.read();
			if (done) break;
			const text = decoder.decode(value);
			if (text.trim()) {
				console.log(text.trim());
			}
		}
	}

	private async watchExit(subprocess: Bun.PipedSubprocess): Promise<void> {
		const exitCode = await subprocess.exited;
		if (this.process !== subprocess) {
			return;
		}
		this.process = null;
		this.stdin = null;
		this.acp = null;
		this.initialized = false;
		this.sessionId = null;
		this.currentCwd = null;
		this.processCwd = null;
		this.processPermissionMode = null;
		this.running = false;
		this.permissionRequests.clear();
		this.configOptions = [];
		this.slashCommands = [];
		this.stopTurnWatchdog();
		this.transport?.failAll(new AcpError("process_exit", `Agent ACP process exited with code ${exitCode}.`));
		this.transport = null;
		if (exitCode !== 0) {
			this.emit({ kind: "error", message: `Agent ACP process exited with code ${exitCode}.` });
		}
	}
}

function normalizeContent(value: JsonValue | undefined): AgentContentBlock {
	const object = asObject(value);
	if (object.type === "text") {
		return { type: "text", text: asString(object.text) };
	}
	return { type: asString(object.type, "unknown"), ...object };
}

function mergeContentBlock(left: AgentContentBlock, right: AgentContentBlock): AgentContentBlock {
	if (left.type === "text" && right.type === "text") {
		return { type: "text", text: `${left.text}${right.text}` };
	}
	return right;
}

function upsertTranscriptUpdate(current: AgentUpdate[], update: AgentUpdate): AgentUpdate[] {
	if (update.kind === "message") {
		const exactIndex = update.messageId
			? current.findIndex(
					(entry) => entry.kind === "message" && entry.messageId === update.messageId && entry.role === update.role,
				)
			: -1;
		const lastIndex = current.length - 1;
		const lastEntry = current[lastIndex];
		const contiguousIndex = lastEntry?.kind === "message" && lastEntry.role === update.role ? lastIndex : -1;
		const index = exactIndex >= 0 ? exactIndex : contiguousIndex;
		if (index < 0) {
			return [...current, update];
		}
		return current.map((entry, entryIndex) =>
			entryIndex === index && entry.kind === "message"
				? { ...entry, content: mergeContentBlock(entry.content, update.content) }
				: entry,
		);
	}
	if (update.kind === "plan") {
		const index = current.findIndex((entry) => entry.kind === "plan");
		if (index < 0) {
			return [...current, update];
		}
		return current.map((entry, entryIndex) => (entryIndex === index ? update : entry));
	}
	if (update.kind === "usage") {
		const index = current.findIndex((entry) => entry.kind === "usage");
		if (index < 0) {
			return [...current, update];
		}
		return current.map((entry, entryIndex) => (entryIndex === index ? update : entry));
	}
	if (update.kind === "tool") {
		const index = current.findIndex(
			(entry) => entry.kind === "tool" && entry.tool.toolCallId === update.tool.toolCallId,
		);
		if (index < 0) {
			return [...current, update];
		}
		return current.map((entry, entryIndex) =>
			entryIndex === index && entry.kind === "tool"
				? {
						kind: "tool",
						tool: {
							...entry.tool,
							toolCallId: update.tool.toolCallId || entry.tool.toolCallId,
							title: update.tool.title && update.tool.title !== "Agent tool" ? update.tool.title : entry.tool.title,
							kind: update.tool.kind && update.tool.kind !== "tool" ? update.tool.kind : entry.tool.kind,
							status: update.tool.status || entry.tool.status,
							content: update.tool.content ?? entry.tool.content,
							locations: update.tool.locations ?? entry.tool.locations,
							rawInput: update.tool.rawInput ?? entry.tool.rawInput,
						},
					}
				: entry,
		);
	}
	return current;
}

function normalizePlanItem(value: JsonValue): AgentPlanItem {
	const object = asObject(value);
	return {
		title: asString(object.content, asString(object.title, "Untitled step")),
		priority: asOptionalString(object.priority),
		status: asOptionalString(object.status),
	};
}

function normalizeToolCall(value: JsonValue | undefined, options: { isUpdate?: boolean } = {}): AgentToolCall {
	const object = asObject(value);
	return {
		toolCallId: asString(object.toolCallId),
		title: asString(object.title, options.isUpdate ? "" : "Agent tool"),
		kind: asString(object.kind, options.isUpdate ? "" : "tool"),
		status: asString(object.status, options.isUpdate ? "" : "pending"),
		content: Array.isArray(object.content) ? object.content : undefined,
		locations: Array.isArray(object.locations) ? object.locations : undefined,
		rawInput: object.rawInput,
	};
}

function buildPromptContent(prompt: string, attachments: AgentPromptAttachment[] | undefined): JsonValue[] {
	const content: JsonValue[] = [{ type: "text", text: prompt }];
	for (const attachment of attachments ?? []) {
		content.push({
			type: "resource_link",
			uri: `file://${attachment.path}`,
			name: attachment.name,
			...(attachment.type === "directory" ? { description: "Directory" } : {}),
		});
	}
	return content;
}

function normalizeSlashCommand(value: JsonValue): AgentSlashCommand {
	const object = asObject(value);
	const input = asObject(object.input);
	return {
		name: asString(object.name),
		description: asString(object.description),
		hint: asOptionalString(input.hint),
	};
}

function normalizeSessionSummary(value: JsonValue | undefined): AgentSessionSummary {
	const object = asObject(value);
	const meta = asObject(object._meta);
	const title = asString(object.title).trim();
	const displayTitle = title === "New agent session" ? "" : title;
	const cwd = asString(object.cwd);
	return {
		sessionId: asString(object.sessionId),
		title: displayTitle || "New chat",
		cwd,
		isNoProject: resolveAgentCwd(cwd) === homedir(),
		updatedAt: asString(object.updatedAt, new Date(0).toISOString()),
		messageCount: asNumber(meta.messageCount),
	};
}

const rpc = BrowserView.defineRPC<AppRPC>({
	maxRequestTime: 10 * 60 * 1000,
	handlers: {
		requests: {
			toggleMaximizeWindow: () => {
				if (mainWindow.isMaximized()) {
					mainWindow.unmaximize();
				} else {
					mainWindow.maximize();
				}
				return mainWindow.isMaximized();
			},
			selectProjectFolder: async () => {
				const [folder] = await Utils.openFileDialog({
					startingFolder: homedir(),
					allowedFileTypes: "*",
					canChooseFiles: false,
					canChooseDirectory: true,
					allowsMultipleSelection: false,
				});
				return folder && folder.trim().length > 0 ? folder : null;
			},
			selectAttachmentFile: async () => {
				const [file] = await Utils.openFileDialog({
					startingFolder: homedir(),
					allowedFileTypes: "*",
					canChooseFiles: true,
					canChooseDirectory: false,
					allowsMultipleSelection: false,
				});
				return file && file.trim().length > 0 ? file : null;
			},
			selectAttachmentFolder: async () => {
				const [folder] = await Utils.openFileDialog({
					startingFolder: homedir(),
					allowedFileTypes: "*",
					canChooseFiles: false,
					canChooseDirectory: true,
					allowsMultipleSelection: false,
				});
				return folder && folder.trim().length > 0 ? folder : null;
			},
			startAgentPrompt: (params: StartAgentPromptParams): StartAgentPromptResponse => {
				const prompt = params.prompt.trim();
				if (!prompt) {
					return { accepted: false };
				}
				agentClient ??= new AgentAcpClient(sendAgentUpdate);
				if (agentClient.isRunning) {
					return { accepted: false };
				}
				void agentClient.startPrompt({ ...params, prompt });
				return { accepted: true };
			},
			prepareAgentSession: async (params: PrepareAgentSessionParams): Promise<PrepareAgentSessionResponse> => {
				agentClient ??= new AgentAcpClient(sendAgentUpdate);
				return agentClient.prepareSession(params);
			},
			cancelAgentPrompt: () => {
				return agentClient?.cancelActiveTurn() ?? false;
			},
			respondToAgentPermission: (params: RespondToAgentPermissionParams) => {
				return agentClient?.respondToPermission(params) ?? false;
			},
			listAgentSessions: async () => {
				return agentClient?.listSessions() ?? [];
			},
			listAgentSlashCommands: async () => {
				return agentClient?.listSlashCommands() ?? [];
			},
			listAgentSkills: async () => {
				return agentClient?.listSkills() ?? [];
			},
			loadAgentSession: async (params: LoadAgentSessionParams) => {
				if (!agentClient) {
					return { loaded: false, reason: "The agent has not started yet." };
				}
				return agentClient.loadSession(params);
			},
			deleteAgentSession: async (params: DeleteAgentSessionParams): Promise<DeleteAgentSessionResponse> => {
				if (!agentClient) {
					return { deleted: false, reason: "The agent has not started yet." };
				}
				return agentClient.deleteSession(params);
			},
			startNewAgentChat: async () => {
				if (!agentClient) {
					return true;
				}
				return agentClient.startNewChat();
			},
			resetAgentChat: async () => {
				await agentClient?.reset();
				agentClient = null;
				return true;
			},
			getProjectGitStatus: (params: GetProjectGitStatusParams) => {
				return getProjectGitStatus(params.cwd);
			},
		},
		messages: {},
	},
});

// Electrobun's webview doesn't wire up standard text-editing keyboard shortcuts
// (cmd+a/cmd+c/cmd+v/cmd+x/cmd+z) on its own; they only work once the app
// registers a native Edit menu with the corresponding roles.
ApplicationMenu.setApplicationMenu([
	{
		submenu: [{ label: "Quit", role: "quit" }],
	},
	{
		label: "Edit",
		submenu: [
			{ role: "undo" },
			{ role: "redo" },
			{ type: "separator" },
			{ role: "cut" },
			{ role: "copy" },
			{ role: "paste" },
			{ role: "pasteAndMatchStyle" },
			{ role: "delete" },
			{ role: "selectAll" },
		],
	},
]);

mainWindow = new BrowserWindow({
	title: "Level5 Build",
	url,
	titleBarStyle: "hiddenInset",
	frame: {
		width: 1280,
		height: 800,
		x: 200,
		y: 200,
	},
	rpc,
});

process.on("exit", () => {
	agentClient?.reset();
});

console.log("App started!");
