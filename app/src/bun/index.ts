import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { BrowserWindow, BrowserView, Updater, Utils } from "electrobun/bun";
import type {
	AppRPC,
	ApprovalModeId,
	MockAgentUpdate,
	MockConfigOption,
	MockContentBlock,
	MockModelId,
	MockPermissionRequest,
	MockPlanItem,
	MockToolCall,
	RespondToMockPermissionParams,
	StartMockPromptParams,
	StartMockPromptResponse,
} from "@shared/rpc";

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;
const MOCK_MODELS = new Set<MockModelId>(["mock-fast", "mock-pro", "mock-deep"]);
const MOCK_MODES = new Set<ApprovalModeId>(["ask", "architect", "code", "auto"]);
const DEFAULT_MODEL: MockModelId = "mock-pro";
const DEFAULT_MODE: ApprovalModeId = "ask";

type JsonPrimitive = string | number | boolean | null;
type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };
type JsonObject = { [key: string]: JsonValue };
type RpcId = string | number | null;
type RpcRequest = {
	jsonrpc: "2.0";
	id: RpcId;
	method: string;
	params?: JsonValue;
};
type RpcNotification = {
	jsonrpc: "2.0";
	method: string;
	params?: JsonValue;
};
type RpcResponse =
	| { jsonrpc: "2.0"; id: RpcId; result: JsonValue }
	| { jsonrpc: "2.0"; id: RpcId; error: { code: number; message: string; data?: JsonValue } };
type RpcMessage = RpcRequest | RpcNotification | RpcResponse;
type PendingRequest = {
	resolve: (value: JsonValue) => void;
	reject: (error: Error) => void;
};

const bundledMainDir = dirname(fileURLToPath(import.meta.url));

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

function normalizeMode(mode: string | undefined): ApprovalModeId {
	return MOCK_MODES.has(mode as ApprovalModeId) ? (mode as ApprovalModeId) : DEFAULT_MODE;
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

function asObject(value: JsonValue | undefined): JsonObject {
	if (!value || typeof value !== "object" || Array.isArray(value)) {
		return {};
	}
	return value as JsonObject;
}

function asString(value: JsonValue | undefined, fallback = ""): string {
	return typeof value === "string" ? value : fallback;
}

function asOptionalString(value: JsonValue | undefined): string | undefined {
	return typeof value === "string" ? value : undefined;
}

class MockAcpClient {
	private process: Bun.PipedSubprocess | null = null;
	private stdin: Bun.PipedSubprocess["stdin"] | null = null;
	private nextId = 1;
	private stdoutBuffer = "";
	private readonly pending = new Map<RpcId, PendingRequest>();
	private readonly permissionRequests = new Map<RpcId, MockPermissionRequest>();
	private initialized = false;
	private sessionId: string | null = null;
	private currentCwd: string | null = null;
	private running = false;

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
		const approvalMode = normalizeMode(params.approvalMode);
		this.emit({ kind: "status", status: "starting", cwd, sessionId: this.sessionId ?? undefined });

		try {
			await this.ensureProcess();
			await this.ensureInitialized();
			await this.ensureSession(cwd);
			if (!this.sessionId) {
				throw new Error("Mock ACP session was not created.");
			}

			await this.request("session/set_config_option", {
				sessionId: this.sessionId,
				configId: "model",
				value: model,
			});
			await this.request("session/set_config_option", {
				sessionId: this.sessionId,
				configId: "mode",
				value: approvalMode,
			});

			this.emit({ kind: "status", status: "running", cwd, sessionId: this.sessionId });
			const result = asObject(
				await this.request("session/prompt", {
					sessionId: this.sessionId,
					prompt: [{ type: "text", text: params.prompt }],
				}),
			);
			this.emit({ kind: "stop", stopReason: asString(result.stopReason, "end_turn") });
			this.emit({ kind: "status", status: "completed", cwd, sessionId: this.sessionId });
		} catch (error) {
			this.emit({
				kind: "error",
				message: error instanceof Error ? error.message : "Mock ACP request failed.",
			});
			this.emit({ kind: "status", status: "error", cwd, sessionId: this.sessionId ?? undefined });
		} finally {
			this.running = false;
		}
	}

	respondToPermission({ requestId, optionId }: RespondToMockPermissionParams): boolean {
		if (!this.permissionRequests.has(requestId)) {
			return false;
		}
		this.permissionRequests.delete(requestId);
		this.writeMessage({ jsonrpc: "2.0", id: requestId, result: { outcome: { optionId } } });
		return true;
	}

	async reset(): Promise<void> {
		this.running = false;
		for (const [, pending] of this.pending) {
			pending.reject(new Error("Mock ACP client reset."));
		}
		this.pending.clear();
		this.permissionRequests.clear();
		this.stdin?.end();
		this.stdin = null;
		this.process?.kill();
		this.process = null;
		this.initialized = false;
		this.sessionId = null;
		this.currentCwd = null;
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
		void this.readStdout(subprocess.stdout);
		void this.readStderr(subprocess.stderr);
		void this.watchExit(subprocess);
	}

	private async ensureInitialized(): Promise<void> {
		if (this.initialized) {
			return;
		}

		await this.request("initialize", {
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
			await this.request("session/close", { sessionId: this.sessionId }).catch(() => undefined);
			this.sessionId = null;
			this.currentCwd = null;
		}

		const result = asObject(
			await this.request("session/new", {
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
		this.emit({ kind: "status", status: "starting", sessionId, cwd });
		this.emitConfig(result.configOptions);
	}

	private request(method: string, params?: JsonValue): Promise<JsonValue> {
		const id = this.nextId++;
		this.writeMessage({ jsonrpc: "2.0", id, method, params });
		return new Promise((resolve, reject) => {
			this.pending.set(id, { resolve, reject });
		});
	}

	private writeMessage(message: RpcMessage): void {
		if (!this.stdin) {
			throw new Error("Mock ACP server is not running.");
		}
		this.stdin.write(`${JSON.stringify(message)}\n`);
	}

	private async readStdout(stdout: ReadableStream<Uint8Array>): Promise<void> {
		const reader = stdout.getReader();
		const decoder = new TextDecoder();
		try {
			while (true) {
				const { done, value } = await reader.read();
				if (done) break;
				this.stdoutBuffer += decoder.decode(value, { stream: true });
				this.flushStdoutLines();
			}
		} catch (error) {
			this.emit({
				kind: "error",
				message: error instanceof Error ? error.message : "Failed to read mock ACP stdout.",
			});
		} finally {
			this.stdoutBuffer += decoder.decode();
			this.flushStdoutLines();
		}
	}

	private flushStdoutLines(): void {
		let newlineIndex = this.stdoutBuffer.indexOf("\n");
		while (newlineIndex >= 0) {
			const line = this.stdoutBuffer.slice(0, newlineIndex).trim();
			this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);
			if (line) {
				this.handleLine(line);
			}
			newlineIndex = this.stdoutBuffer.indexOf("\n");
		}
	}

	private handleLine(line: string): void {
		let message: RpcMessage;
		try {
			message = JSON.parse(line) as RpcMessage;
		} catch {
			this.emit({ kind: "error", message: `Malformed mock ACP JSON: ${line.slice(0, 120)}` });
			return;
		}

		if ("id" in message && ("result" in message || "error" in message)) {
			this.handleResponse(message);
			return;
		}
		if ("method" in message && "id" in message) {
			this.handleServerRequest(message);
			return;
		}
		if ("method" in message) {
			this.handleNotification(message);
		}
	}

	private handleResponse(message: RpcResponse): void {
		const pending = this.pending.get(message.id);
		if (!pending) {
			return;
		}
		this.pending.delete(message.id);
		if ("error" in message) {
			pending.reject(new Error(message.error.message));
			return;
		}
		pending.resolve(message.result);
	}

	private handleServerRequest(message: RpcRequest): void {
		if (message.method !== "session/request_permission") {
			this.writeMessage({
				jsonrpc: "2.0",
				id: message.id,
				error: { code: -32601, message: `Unsupported client request: ${message.method}` },
			});
			return;
		}

		const params = asObject(message.params);
		const request: MockPermissionRequest = {
			requestId: message.id ?? "",
			sessionId: asString(params.sessionId, this.sessionId ?? ""),
			toolCall: normalizeToolCall(params.toolCall),
			options: Array.isArray(params.options)
				? params.options.map((option) => {
						const object = asObject(option);
						return {
							optionId: asString(object.optionId),
							name: asString(object.name, asString(object.optionId)),
							kind: asOptionalString(object.kind),
						};
					})
				: [],
		};
		this.permissionRequests.set(message.id, request);
		this.emit({ kind: "permission", request });
	}

	private handleNotification(message: RpcNotification): void {
		if (message.method !== "session/update") {
			return;
		}
		const params = asObject(message.params);
		const update = asObject(params.update);
		const updateType = asString(update.sessionUpdate);

		if (updateType === "user_message_chunk" || updateType === "agent_message_chunk") {
			this.emit({
				kind: "message",
				role: updateType === "user_message_chunk" ? "user" : "agent",
				messageId: asString(update.messageId),
				content: normalizeContent(update.content),
			});
			return;
		}
		if (updateType === "plan") {
			this.emit({
				kind: "plan",
				items: Array.isArray(update.entries) ? update.entries.map(normalizePlanItem) : [],
			});
			return;
		}
		if (updateType === "tool_call") {
			this.emit({ kind: "tool", tool: normalizeToolCall(update) });
			return;
		}
		if (updateType === "tool_call_update") {
			this.emit({ kind: "tool", tool: normalizeToolCall(update) });
			return;
		}
		if (updateType === "config_option_update") {
			this.emitConfig(update.configOptions);
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
		this.initialized = false;
		this.sessionId = null;
		this.currentCwd = null;
		this.running = false;
		for (const [, pending] of this.pending) {
			pending.reject(new Error(`Mock ACP server exited with code ${exitCode}.`));
		}
		this.pending.clear();
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
			resetMockChat: async () => {
				await mockClient?.reset();
				mockClient = null;
				return true;
			},
		},
		messages: {},
	},
});

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
