import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
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
import { APPROVAL_MODE_LABELS } from "../shared/rpc";
import type {
	AppRPC,
	ApprovalModeId,
	DeleteMockSessionParams,
	DeleteMockSessionResponse,
	LoadMockSessionParams,
	LoadMockSessionResponse,
	MockAgentUpdate,
	MockConfigOption,
	MockContentBlock,
	MockModelId,
	MockPermissionOption,
	MockPermissionRequest,
	MockPlanItem,
	MockPromptAttachment,
	MockSessionSummary,
	MockSkill,
	MockSlashCommand,
	MockToolCall,
	RespondToMockPermissionParams,
	StartMockPromptParams,
	StartMockPromptResponse,
} from "../shared/rpc";

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;
const MOCK_MODELS = new Set<MockModelId>(["mock-fast", "mock-pro", "mock-deep"]);
const MOCK_APPROVAL_MODES = new Set<ApprovalModeId>(["ask", "auto", "full-access"]);
const DEFAULT_MODEL: MockModelId = "mock-pro";
const DEFAULT_APPROVAL_MODE: ApprovalModeId = "ask";

const bundledMainDir = dirname(fileURLToPath(import.meta.url));
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
let mockClient: MockAcpClient | null = null;

function sendMockUpdate(update: MockAgentUpdate) {
	rpc.send.mockAgentUpdate(update);
}

function normalizeModel(model: string | undefined): MockModelId {
	return MOCK_MODELS.has(model as MockModelId) ? (model as MockModelId) : DEFAULT_MODEL;
}

function normalizeApprovalMode(mode: string | undefined): ApprovalModeId {
	return MOCK_APPROVAL_MODES.has(mode as ApprovalModeId) ? (mode as ApprovalModeId) : DEFAULT_APPROVAL_MODE;
}

function pickAutoApproveOptionId(options: MockPermissionOption[]): string | undefined {
	return options.find((option) => option.kind?.startsWith("allow"))?.optionId ?? options[0]?.optionId;
}

function findMockServerPaths(): { mockServerDir: string; mockServerEntrypoint: string } {
	for (const start of [process.cwd(), bundledMainDir]) {
		let current = resolve(start);
		while (true) {
			const candidateDir = resolve(current, "acp-mock-server");
			const candidateEntrypoint = resolve(candidateDir, "src/index.ts");
			if (existsSync(candidateEntrypoint)) {
				return { mockServerDir: candidateDir, mockServerEntrypoint: candidateEntrypoint };
			}

			const parent = dirname(current);
			if (parent === current) {
				break;
			}
			current = parent;
		}
	}

	throw new Error("Unable to locate bundled acp-mock-server/src/index.ts.");
}

function getBunRuntimePath(): string {
	const bundledRuntime = resolve(dirname(process.execPath), process.platform === "win32" ? "bun.exe" : "bun");
	return existsSync(bundledRuntime) ? bundledRuntime : process.execPath;
}

function resolveCwd(cwd: string | null | undefined): string {
	if (!cwd || cwd.trim().length === 0 || cwd.trim() === "~/" || cwd.trim() === "~") {
		return homedir();
	}
	if (cwd.startsWith("~/")) {
		return resolve(homedir(), cwd.slice(2));
	}
	return cwd;
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

class MockAcpClient {
	private process: Bun.PipedSubprocess | null = null;
	private stdin: Bun.PipedSubprocess["stdin"] | null = null;
	private transport: AcpJsonRpcTransport | null = null;
	private acp: AcpClient | null = null;
	private readonly permissionRequests = new Map<RpcId, MockPermissionRequest>();
	private readonly sessions = new Map<string, MockSessionSummary>();
	private readonly transcripts = new Map<string, MockAgentUpdate[]>();
	private turnWatchdog: AcpTurnIdleWatchdog | null = null;
	private initialized = false;
	private sessionId: string | null = null;
	private currentCwd: string | null = null;
	private running = false;
	private approvalMode: ApprovalModeId = DEFAULT_APPROVAL_MODE;

	constructor(private readonly emit: (update: MockAgentUpdate) => void) {}

	get isRunning() {
		return this.running;
	}

	async startPrompt(params: StartMockPromptParams): Promise<void> {
		if (this.running) {
			this.emit({ kind: "error", message: "A mock agent turn is already running." });
			return;
		}

		this.running = true;
		const cwd = resolveCwd(params.cwd);
		const model = normalizeModel(params.model);
		this.approvalMode = normalizeApprovalMode(params.approvalMode);
		this.emit({ kind: "status", status: "starting", cwd, sessionId: this.sessionId ?? undefined });

		try {
			await this.ensureProcess();
			await this.ensureInitialized();
			await this.ensureSession(cwd);
			if (!this.sessionId) {
				throw new Error("Mock ACP session was not created.");
			}

			await this.requireAcp().setConfigOption({
				sessionId: this.sessionId,
				configId: "model",
				value: model,
			});

			this.emit({ kind: "status", status: "running", cwd, sessionId: this.sessionId });
			this.startTurnWatchdog();
			const result = asObject(
				await this.requireAcp().prompt({
					sessionId: this.sessionId,
					prompt: buildPromptContent(params.prompt, params.attachments),
				}),
			);
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
			this.emit({
				kind: "error",
				message: error instanceof Error ? error.message : "Mock ACP request failed.",
			});
			this.emit({ kind: "status", status: "error", cwd, sessionId: this.sessionId ?? undefined });
		} finally {
			this.stopTurnWatchdog();
			this.running = false;
		}
	}

	respondToPermission({ requestId, optionId }: RespondToMockPermissionParams): boolean {
		if (!this.permissionRequests.has(requestId)) {
			return false;
		}
		this.permissionRequests.delete(requestId);
		this.turnWatchdog?.setAwaitingHuman(false);
		this.turnWatchdog?.touch();
		this.requireAcp().respondSuccess(requestId, { outcome: { optionId } });
		return true;
	}

	async listSessions(): Promise<MockSessionSummary[]> {
		await this.ensureProcess();
		await this.ensureInitialized();
		let cursor: string | undefined;
		do {
			const result = asObject(
				await this.requireAcp().listSessions(cursor ? { cursor } : undefined),
			);
			const sessionValues = Array.isArray(result.sessions) ? result.sessions : [];
			for (const sessionValue of sessionValues) {
				this.rememberSession(normalizeSessionSummary(sessionValue), false);
			}
			cursor = asOptionalString(result.nextCursor);
		} while (cursor);

		return this.sortedSessions();
	}

	async listSlashCommands(): Promise<MockSlashCommand[]> {
		await this.ensureProcess();
		await this.ensureInitialized();
		const result = asObject(await this.requireAcp().requestExtension("_mock/list_slash_commands"));
		const commands = Array.isArray(result.availableCommands) ? result.availableCommands : [];
		return commands.map(normalizeSlashCommand);
	}

	async listSkills(): Promise<MockSkill[]> {
		await this.ensureProcess();
		await this.ensureInitialized();
		const result = asObject(await this.requireAcp().requestExtension("_mock/list_skills"));
		const skills = Array.isArray(result.skills) ? result.skills : [];
		return skills.map(normalizeSkill);
	}

	async loadSession({ sessionId }: LoadMockSessionParams): Promise<LoadMockSessionResponse> {
		if (this.running) {
			return { loaded: false, reason: "A mock agent turn is already running." };
		}
		if (!sessionId) {
			return { loaded: false, reason: "No session was selected." };
		}

		try {
			const session = this.sessions.get(sessionId);
			if (!session) {
				return { loaded: false, reason: "That chat no longer exists." };
			}

			await this.ensureProcess();
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

	async deleteSession({ sessionId }: DeleteMockSessionParams): Promise<DeleteMockSessionResponse> {
		if (!sessionId) {
			return { deleted: false, reason: "No session was selected." };
		}
		if (this.running && sessionId === this.sessionId) {
			return { deleted: false, reason: "Wait for the active agent turn to finish before deleting this chat." };
		}

		try {
			await this.ensureProcess();
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
		this.transport?.failAll(new AcpError("transport_failure", "Mock ACP client reset."));
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
		this.approvalMode = DEFAULT_APPROVAL_MODE;
		this.sessions.clear();
		this.transcripts.clear();
		this.emit({ kind: "status", status: "idle" });
	}

	private async ensureProcess(): Promise<void> {
		if (this.process) {
			return;
		}

		const { mockServerDir, mockServerEntrypoint } = findMockServerPaths();
		const subprocess = Bun.spawn({
			cmd: [getBunRuntimePath(), mockServerEntrypoint],
			cwd: mockServerDir,
			stdin: "pipe",
			stdout: "pipe",
			stderr: "pipe",
			env: {
				...process.env,
				ACP_MOCK_LOG: process.env.ACP_MOCK_LOG ?? "info",
				ACP_MOCK_STATE_PATH: process.env.ACP_MOCK_STATE_PATH ?? resolve(homedir(), ".level5-build", "acp-mock-state.json"),
			},
		});
		this.process = subprocess;
		this.stdin = subprocess.stdin;
		this.transport = new AcpJsonRpcTransport({
			writeLine: (line) => {
				if (!this.stdin) {
					throw new AcpError("transport_failure", "Mock ACP server is not running.");
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
		void this.readStdout(subprocess.stdout);
		void this.readStderr(subprocess.stderr);
		void this.watchExit(subprocess);
	}

	private async ensureInitialized(): Promise<void> {
		if (this.initialized) {
			return;
		}

		await this.requireAcp().initialize({
			protocolVersion: 1,
			clientInfo: { name: "level5-build", version: "0.0.0" },
			clientCapabilities: {
				fs: { readTextFile: true, writeTextFile: true },
				terminal: true,
			},
		});
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
			throw new Error("Mock ACP server did not return a session id.");
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

	private rememberSession(session: MockSessionSummary, shouldEmit = true): MockSessionSummary {
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

	private sortedSessions(): MockSessionSummary[] {
		return [...this.sessions.values()].sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
	}

	private rememberTranscriptUpdate(sessionId: string, update: MockAgentUpdate): void {
		if (!sessionId) {
			return;
		}
		const current = this.transcripts.get(sessionId) ?? [];
		this.transcripts.set(sessionId, upsertTranscriptUpdate(current, update));
	}

	private emitTranscriptUpdate(sessionId: string, update: MockAgentUpdate): void {
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
				const error = new AcpError("request_timeout", `Mock ACP turn went silent for ${Math.round(idleMs / 1000)}s.`);
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
			throw new AcpError("transport_failure", "Mock ACP server is not running.");
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
				message: error instanceof Error ? error.message : "Failed to read mock ACP stdout.",
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
		const options: MockPermissionOption[] = Array.isArray(params.options)
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
				this.requireAcp().respondSuccess(message.id, { outcome: { optionId: autoOptionId } });
				this.emit({
					kind: "info",
					id: String(message.id),
					message: `Auto-approved "${toolCall.title}" (${APPROVAL_MODE_LABELS[this.approvalMode]} mode).`,
				});
				return;
			}
		}

		const request: MockPermissionRequest = {
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
			this.emitTranscriptUpdate(sessionId, { kind: "tool", tool: normalizeToolCall(update) });
			return;
		}
		if (updateType === "tool_call_update") {
			this.emitTranscriptUpdate(sessionId, { kind: "tool", tool: normalizeToolCall(update) });
			return;
		}
		if (updateType === "config_option_update") {
			this.emitConfig(update.configOptions);
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
		this.emit({
			kind: "config",
			options: value.map((entry) => {
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
				} satisfies MockConfigOption;
			}),
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
		this.running = false;
		this.stopTurnWatchdog();
		this.transport?.failAll(new AcpError("process_exit", `Mock ACP server exited with code ${exitCode}.`));
		this.transport = null;
		if (exitCode !== 0) {
			this.emit({ kind: "error", message: `Mock ACP server exited with code ${exitCode}.` });
		}
	}
}

function normalizeContent(value: JsonValue | undefined): MockContentBlock {
	const object = asObject(value);
	if (object.type === "text") {
		return { type: "text", text: asString(object.text) };
	}
	return { type: asString(object.type, "unknown"), ...object };
}

function mergeContentBlock(left: MockContentBlock, right: MockContentBlock): MockContentBlock {
	if (left.type === "text" && right.type === "text") {
		return { type: "text", text: `${left.text}${right.text}` };
	}
	return right;
}

function upsertTranscriptUpdate(current: MockAgentUpdate[], update: MockAgentUpdate): MockAgentUpdate[] {
	if (update.kind === "message") {
		const index = current.findIndex(
			(entry) => entry.kind === "message" && entry.messageId === update.messageId && entry.role === update.role,
		);
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
		return [...current.filter((entry) => entry.kind !== "plan"), update];
	}
	if (update.kind === "usage") {
		return [...current.filter((entry) => entry.kind !== "usage"), update];
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
							...update.tool,
							title: update.tool.title === "Mock tool" ? entry.tool.title : update.tool.title,
							kind: update.tool.kind === "tool" ? entry.tool.kind : update.tool.kind,
						},
					}
				: entry,
		);
	}
	return current;
}

function normalizePlanItem(value: JsonValue): MockPlanItem {
	const object = asObject(value);
	return {
		title: asString(object.content, asString(object.title, "Untitled step")),
		priority: asOptionalString(object.priority),
		status: asOptionalString(object.status),
	};
}

function normalizeToolCall(value: JsonValue | undefined): MockToolCall {
	const object = asObject(value);
	return {
		toolCallId: asString(object.toolCallId),
		title: asString(object.title, "Mock tool"),
		kind: asString(object.kind, "tool"),
		status: asString(object.status, "pending"),
		content: Array.isArray(object.content) ? object.content : undefined,
		locations: Array.isArray(object.locations) ? object.locations : undefined,
		rawInput: object.rawInput,
	};
}

function buildPromptContent(prompt: string, attachments: MockPromptAttachment[] | undefined): JsonValue[] {
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

function normalizeSlashCommand(value: JsonValue): MockSlashCommand {
	const object = asObject(value);
	const input = asObject(object.input);
	return {
		name: asString(object.name),
		description: asString(object.description),
		hint: asOptionalString(input.hint),
	};
}

function normalizeSkill(value: JsonValue): MockSkill {
	const object = asObject(value);
	return {
		id: asString(object.id),
		name: asString(object.name),
		description: asString(object.description),
	};
}

function normalizeSessionSummary(value: JsonValue | undefined): MockSessionSummary {
	const object = asObject(value);
	const meta = asObject(object._meta);
	const title = asString(object.title).trim();
	const displayTitle = title === "New mock agent session" ? "" : title;
	const cwd = asString(object.cwd);
	return {
		sessionId: asString(object.sessionId),
		title: displayTitle || "New chat",
		cwd,
		isNoProject: resolveCwd(cwd) === homedir(),
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
			startMockPrompt: (params: StartMockPromptParams): StartMockPromptResponse => {
				const prompt = params.prompt.trim();
				if (!prompt) {
					return { accepted: false };
				}
				mockClient ??= new MockAcpClient(sendMockUpdate);
				if (mockClient.isRunning) {
					return { accepted: false };
				}
				void mockClient.startPrompt({ ...params, prompt });
				return { accepted: true };
			},
			respondToMockPermission: (params: RespondToMockPermissionParams) => {
				return mockClient?.respondToPermission(params) ?? false;
			},
			listMockSessions: async () => {
				mockClient ??= new MockAcpClient(sendMockUpdate);
				return mockClient.listSessions();
			},
			listMockSlashCommands: async () => {
				mockClient ??= new MockAcpClient(sendMockUpdate);
				return mockClient.listSlashCommands();
			},
			listMockSkills: async () => {
				mockClient ??= new MockAcpClient(sendMockUpdate);
				return mockClient.listSkills();
			},
			loadMockSession: async (params: LoadMockSessionParams) => {
				if (!mockClient) {
					return { loaded: false, reason: "The mock agent has not started yet." };
				}
				return mockClient.loadSession(params);
			},
			deleteMockSession: async (params: DeleteMockSessionParams): Promise<DeleteMockSessionResponse> => {
				if (!mockClient) {
					return { deleted: false, reason: "The mock agent has not started yet." };
				}
				return mockClient.deleteSession(params);
			},
			startNewMockChat: async () => {
				if (!mockClient) {
					return true;
				}
				return mockClient.startNewChat();
			},
			resetMockChat: async () => {
				await mockClient?.reset();
				mockClient = null;
				return true;
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
	mockClient?.reset();
});

console.log("App started!");
