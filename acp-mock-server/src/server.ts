import { availableCommands, buildConfigOptions, defaultConfig, mockSkills, supportedModes } from "./fixtures";
import {
	JsonRpcErrorCode,
	RpcException,
	isRpcNotification,
	isRpcResponse,
	notify,
	parseRpcLine,
	respond,
	respondError,
	writeMessage
} from "./rpc";
import { StateStore } from "./state";
import type { ContentBlock, JsonObject, JsonValue, Logger, RpcId, RpcMessage, RpcRequest, RpcResponse, SessionRecord } from "./types";

type PendingClientRequest = {
	resolve: (value: JsonValue) => void;
	reject: (error: Error) => void;
};

type ActiveTurn = {
	cancelled: boolean;
	cancel: () => void;
};

const authRequiredError = { code: -32001, message: "auth_required" };

export class AcpMockServer {
	private initialized = false;
	private authenticated = process.env.ACP_MOCK_AUTH_REQUIRED !== "1";
	private clientCapabilities: JsonObject = {};
	private nextClientRequestId = 10000;
	private readonly pendingClientRequests = new Map<RpcId, PendingClientRequest>();
	private readonly activeTurns = new Map<string, ActiveTurn>();

	constructor(
		private readonly store: StateStore,
		private readonly logger: Logger,
		private readonly delayMs = Number(process.env.ACP_MOCK_DELAY_MS ?? "120")
	) {}

	async handleLine(line: string): Promise<void> {
		let message: RpcMessage;
		try {
			message = parseRpcLine(line);
		} catch (error) {
			respondError(null, error instanceof SyntaxError ? new RpcException(JsonRpcErrorCode.ParseError, "Parse error") : error);
			return;
		}

		if (isRpcResponse(message)) {
			this.handleClientResponse(message);
			return;
		}
		if ("method" in message && "id" in message) {
			const request = message as RpcRequest;
			await this.handleRequest(request.id, request.method, request.params);
			return;
		}
		if (isRpcNotification(message)) {
			await this.handleNotification(message.method, message.params);
			return;
		}
		respondError(null, new RpcException(JsonRpcErrorCode.InvalidRequest, "Invalid JSON-RPC message"));
	}

	private async handleRequest(id: RpcId, method: string, params: JsonValue | undefined): Promise<void> {
		try {
			const result = await this.dispatch(method, params);
			respond(id, result);
		} catch (error) {
			respondError(id, error);
		}
	}

	private async handleNotification(method: string, params: JsonValue | undefined): Promise<void> {
		try {
			if (method === "session/cancel") {
				const session = this.requireSession(params);
				const active = this.activeTurns.get(session.sessionId);
				if (active) active.cancel();
				return;
			}
			this.logger.debug(`ignored notification ${method}`);
		} catch (error) {
			this.logger.error(error instanceof Error ? error.message : String(error));
		}
	}

	private handleClientResponse(message: RpcResponse): void {
		const pending = this.pendingClientRequests.get(message.id);
		if (!pending) {
			this.logger.debug(`unexpected client response id ${String(message.id)}`);
			return;
		}
		this.pendingClientRequests.delete(message.id);
		if ("error" in message) {
			pending.reject(new Error(message.error.message));
			return;
		}
		pending.resolve(message.result);
	}

	private async dispatch(method: string, params: JsonValue | undefined): Promise<JsonValue> {
		if (method !== "initialize" && !this.initialized) {
			throw new RpcException(JsonRpcErrorCode.InvalidRequest, "initialize must be called before other methods");
		}

		switch (method) {
			case "initialize":
				return this.initialize(params);
			case "authenticate":
				return this.authenticate(params);
			case "logout":
				this.authenticated = false;
				return {};
			case "session/new":
				this.requireAuth();
				return this.createSession(params);
			case "session/load":
				this.requireAuth();
				return this.loadSession(params);
			case "session/resume":
				this.requireAuth();
				return this.resumeSession(params);
			case "session/close":
				this.requireAuth();
				return this.closeSession(params);
			case "session/list":
				this.requireAuth();
				return this.listSessions(params);
			case "session/delete":
				this.requireAuth();
				return this.deleteSession(params);
			case "session/set_mode":
				this.requireAuth();
				return this.setMode(params);
			case "session/set_config_option":
				this.requireAuth();
				return this.setConfigOption(params);
			case "session/prompt":
				this.requireAuth();
				return this.prompt(params);
			case "_mock/list_models":
				return { models: this.models(), currentModel: this.currentModel(params) };
			case "_mock/set_model":
				this.requireAuth();
				return this.setModel(params);
			case "_mock/list_skills":
				return { skills: mockSkills as unknown as JsonValue };
			case "_mock/list_slash_commands":
				return { availableCommands: availableCommands as unknown as JsonValue };
			case "_mock/reset":
				return this.resetSession(params);
			default:
				throw new RpcException(JsonRpcErrorCode.MethodNotFound, `Method not found: ${method}`);
		}
	}

	private initialize(params: JsonValue | undefined): JsonValue {
		const object = asObject(params);
		this.initialized = true;
		this.clientCapabilities = asObject(object.clientCapabilities ?? {});
		this.logger.debug(`client capabilities: ${Object.keys(this.clientCapabilities).join(",") || "none"}`);
		this.logger.info(`initialized by ${JSON.stringify(object.clientInfo ?? "unknown client")}`);
		return {
			protocolVersion: 1,
			agentCapabilities: {
				loadSession: true,
				promptCapabilities: {
					image: true,
					audio: true,
					embeddedContext: true
				},
				mcpCapabilities: {
					http: true,
					sse: true
				},
				auth: {
					logout: {}
				},
				sessionCapabilities: {
					list: {},
					delete: {},
					resume: {},
					close: {},
					additionalDirectories: {}
				},
				_meta: {
					"mock/fullSurface": true,
					"mock/directModelApi": true,
					"mock/slashCommandAutocomplete": true,
					"mock/skills": mockSkills
				}
			},
			agentInfo: {
				name: "acp-mock-agent",
				title: "ACP Mock Agent",
				version: "0.1.0"
			},
			authMethods: [
				{
					id: "mock-login",
					name: "Mock login",
					description: "Authenticate against the local mock agent.",
					type: "agent"
				}
			]
		};
	}

	private authenticate(params: JsonValue | undefined): JsonValue {
		const methodId = String(asObject(params).methodId ?? "");
		if (methodId !== "mock-login") {
			throw new RpcException(JsonRpcErrorCode.InvalidParams, "Unknown authentication method");
		}
		this.authenticated = true;
		return {};
	}

	private createSession(params: JsonValue | undefined): JsonValue {
		const object = asObject(params);
		const cwd = requireAbsolutePath(String(object.cwd ?? process.cwd()), "cwd");
		const sessionId = this.store.nextId("session");
		const additionalDirectories = asStringArray(object.additionalDirectories ?? []);
		const now = new Date().toISOString();
		const session: SessionRecord = {
			sessionId,
			cwd,
			additionalDirectories,
			updatedAt: now,
			title: "New mock agent session",
			modeId: defaultConfig.mode,
			config: { ...defaultConfig },
			messages: [],
			_meta: {
				messageCount: 0,
				mockSkills,
				mcpServers: Array.isArray(object.mcpServers) ? object.mcpServers.length : 0
			}
		};
		this.store.saveSession(session);
			setTimeout(() => {
				this.sendAvailableCommands(sessionId);
				this.sendSessionInfo(session, "New mock agent session");
				this.sendConfigUpdate(session);
			}, 0);
		return {
			sessionId,
			modes: this.modeState(session),
			configOptions: buildConfigOptions(session.config)
		};
	}

	private async loadSession(params: JsonValue | undefined): Promise<JsonValue> {
		const session = this.requireSession(params);
		session.cwd = String(asObject(params).cwd ?? session.cwd);
		session.additionalDirectories = asStringArray(asObject(params).additionalDirectories ?? session.additionalDirectories);
		this.store.saveSession(session);
		for (const message of session.messages) {
			for (const content of message.content) {
				this.sendSessionUpdate(session.sessionId, {
					sessionUpdate: message.role === "user" ? "user_message_chunk" : "agent_message_chunk",
					messageId: message.messageId,
					content: content as unknown as JsonValue
				});
				await this.sleep();
			}
		}
		this.sendAvailableCommands(session.sessionId);
		this.sendConfigUpdate(session);
		return {
			modes: this.modeState(session),
			configOptions: buildConfigOptions(session.config)
		};
	}

	private resumeSession(params: JsonValue | undefined): JsonValue {
		const session = this.requireSession(params);
		const object = asObject(params);
		session.cwd = String(object.cwd ?? session.cwd);
		session.additionalDirectories = asStringArray(object.additionalDirectories ?? session.additionalDirectories);
		session.updatedAt = new Date().toISOString();
		this.store.saveSession(session);
		return {
			modes: this.modeState(session),
			configOptions: buildConfigOptions(session.config)
		};
	}

	private closeSession(params: JsonValue | undefined): JsonValue {
		const session = this.requireSession(params);
		const active = this.activeTurns.get(session.sessionId);
		if (active) active.cancel();
		this.activeTurns.delete(session.sessionId);
		return {};
	}

	private listSessions(params: JsonValue | undefined): JsonValue {
		const object = asObject(params ?? {});
		const cwd = typeof object.cwd === "string" ? object.cwd : undefined;
		const cursor = typeof object.cursor === "string" ? Number.parseInt(object.cursor, 10) : 0;
		if (Number.isNaN(cursor)) {
			throw new RpcException(JsonRpcErrorCode.InvalidParams, "Invalid cursor");
		}
		const pageSize = 25;
		const allSessions = Object.values(this.store.snapshot.sessions)
			.filter((session) => !session.deleted)
			.filter((session) => !cwd || session.cwd === cwd)
			.sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
		const page = allSessions.slice(cursor, cursor + pageSize);
		const nextCursor = cursor + pageSize < allSessions.length ? String(cursor + pageSize) : undefined;
		return {
			sessions: page.map((session) => ({
				sessionId: session.sessionId,
				cwd: session.cwd,
				additionalDirectories: session.additionalDirectories,
				...(session.title !== undefined ? { title: session.title } : {}),
				updatedAt: session.updatedAt,
				_meta: {
					...session._meta,
					messageCount: session.messages.length,
					currentModel: session.config.model,
					modeId: session.modeId
				}
			})),
			...(nextCursor ? { nextCursor } : {})
		};
	}

	private deleteSession(params: JsonValue | undefined): JsonValue {
		const sessionId = String(asObject(params).sessionId ?? "");
		if (sessionId) this.store.deleteSession(sessionId);
		return {};
	}

	private setMode(params: JsonValue | undefined): JsonValue {
		const session = this.requireSession(params);
		const modeId = String(asObject(params).modeId ?? "");
		this.applyConfig(session, "mode", modeId);
		this.sendSessionUpdate(session.sessionId, { sessionUpdate: "current_mode_update", modeId });
		this.sendConfigUpdate(session);
		return {};
	}

	private setConfigOption(params: JsonValue | undefined): JsonValue {
		const session = this.requireSession(params);
		const object = asObject(params);
		const configId = String(object.configId ?? "");
		const value = String(object.value ?? "");
		this.applyConfig(session, configId, value);
		this.sendConfigUpdate(session);
		return { configOptions: buildConfigOptions(session.config) };
	}

	private setModel(params: JsonValue | undefined): JsonValue {
		const object = asObject(params);
		const sessionId = typeof object.sessionId === "string" ? object.sessionId : undefined;
		const model = String(object.model ?? object.modelId ?? "");
		const session = sessionId ? this.getSession(sessionId) : undefined;
		if (!this.models().some((entry) => entry.id === model)) {
			throw new RpcException(JsonRpcErrorCode.InvalidParams, `Unknown model: ${model}`);
		}
		if (session) {
			this.applyConfig(session, "model", model);
			this.sendConfigUpdate(session);
		}
		return {
			currentModel: model,
			models: this.models(),
			...(session ? { configOptions: buildConfigOptions(session.config) } : {})
		} as JsonObject;
	}

	private async prompt(params: JsonValue | undefined): Promise<JsonValue> {
		const session = this.requireSession(params);
		const prompt = normalizePrompt(asObject(params).prompt);
		const promptText = prompt.map(contentToText).join("\n").trim();
		const userMessageId = this.store.nextId("message");
		session.messages.push({ role: "user", messageId: userMessageId, content: prompt, createdAt: new Date().toISOString() });
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "user_message_chunk",
			messageId: userMessageId,
			content: prompt[0] as unknown as JsonValue
		});

		const turn: ActiveTurn = {
			cancelled: false,
			cancel: () => {
				turn.cancelled = true;
			}
		};
		this.activeTurns.set(session.sessionId, turn);
		try {
			const stopReason = await this.runScenario(session, promptText, turn);
			session.updatedAt = new Date().toISOString();
			session._meta = { ...session._meta, messageCount: session.messages.length, lastStopReason: stopReason };
			this.store.saveSession(session);
			return { stopReason };
		} catch (error) {
			if (error instanceof CancelledTurn) {
				session.updatedAt = new Date().toISOString();
				session._meta = { ...session._meta, messageCount: session.messages.length, lastStopReason: "cancelled" };
				this.store.saveSession(session);
				return { stopReason: "cancelled" };
			}
			throw error;
		} finally {
			this.activeTurns.delete(session.sessionId);
		}
	}

	private async runScenario(session: SessionRecord, promptText: string, turn: ActiveTurn): Promise<string> {
		this.updateTitleFromPrompt(session, promptText);
		this.sendAvailableCommands(session.sessionId);
		this.sendPlan(session.sessionId, [
			["Understand the request and current session settings", "high", "in_progress"],
			["Select the best mock workflow", "high", "pending"],
			["Stream realistic tool and message updates", "medium", "pending"],
			["Return a protocol stop reason", "medium", "pending"]
		]);
		await this.checkpoint(turn);

		const lower = promptText.toLowerCase();
		if (lower.startsWith("/mode ")) {
			const modeId = lower.replace("/mode", "").trim();
			this.applyConfig(session, "mode", modeId);
			this.sendSessionUpdate(session.sessionId, { sessionUpdate: "current_mode_update", modeId });
			this.sendConfigUpdate(session);
			await this.say(session, `Switched to **${modeId}** mode. I updated both the legacy mode state and config options so either UI path can stay in sync.`);
			return "end_turn";
		}
		if (lower.includes("refuse") || lower.startsWith("/refuse")) {
			await this.say(session, "I cannot continue this mocked request because you asked me to exercise the refusal path.");
			return "refusal";
		}
		if (lower.includes("max token") || lower.startsWith("/tokens")) {
			await this.say(session, "I am intentionally stopping here to simulate a model output limit.");
			return "max_tokens";
		}
		if (lower.includes("fail") || lower.startsWith("/fail")) {
			await this.tool(session, "execute", "Running a command that fails", "failed", "Command exited with status 2. This is a deliberate mock failure.");
			await this.say(session, "The simulated command failed, and I surfaced it through a failed tool call so the client can render the error state.");
			return "end_turn";
		}
		if (lower.includes("permission") || lower.includes("approve")) {
			await this.permissionScenario(session, turn);
			return turn.cancelled ? "cancelled" : "end_turn";
		}
		if (lower.startsWith("/skills") || lower.includes("skill")) {
			await this.skillsScenario(session, turn);
			return turn.cancelled ? "cancelled" : "end_turn";
		}
		if (lower.startsWith("/web") || lower.includes("web") || lower.includes("fetch")) {
			await this.webScenario(session, turn);
			return turn.cancelled ? "cancelled" : "end_turn";
		}
		if (lower.startsWith("/test") || lower.includes("test") || lower.includes("build")) {
			await this.testScenario(session, turn);
			return turn.cancelled ? "cancelled" : "end_turn";
		}
		if (lower.startsWith("/fix") || lower.includes("edit") || lower.includes("fix") || lower.includes("refactor")) {
			await this.editScenario(session, turn);
			return turn.cancelled ? "cancelled" : "end_turn";
		}
		if (lower.startsWith("/plan") || lower.includes("plan")) {
			await this.planScenario(session, turn);
			return turn.cancelled ? "cancelled" : "end_turn";
		}
		await this.defaultScenario(session, turn);
		return turn.cancelled ? "cancelled" : "end_turn";
	}

	private async defaultScenario(session: SessionRecord, turn: ActiveTurn): Promise<void> {
		this.sendPlan(session.sessionId, [
			["Understand the request and session context", "high", "completed"],
			["Inspect likely files and constraints", "high", "in_progress"],
			["Report a concise answer", "medium", "pending"]
		]);
		await this.tool(session, "search", "Scanning workspace structure", "completed", "Found app/, docs/, and acp-mock-server/ roots.", turn);
		await this.usage(session, 1840, 200000, 0.002);
		await this.say(session, "I inspected the mock workspace context and I am ready to help. Try `/plan`, `/fix`, `/test`, `/review`, `/web`, `/skills`, `/mode code`, `permission`, `fail`, `refuse`, or `max tokens` to exercise specific ACP client states.");
	}

	private async planScenario(session: SessionRecord, turn: ActiveTurn): Promise<void> {
		this.sendPlan(session.sessionId, [
			["Clarify the goal and success criteria", "high", "completed"],
			["Map ACP client surfaces that need UI support", "high", "in_progress"],
			["Define implementation and verification steps", "medium", "pending"]
		]);
		await this.checkpoint(turn);
		this.sendPlan(session.sessionId, [
			["Clarify the goal and success criteria", "high", "completed"],
			["Map ACP client surfaces that need UI support", "high", "completed"],
			["Define implementation and verification steps", "medium", "in_progress"],
			["Call out model, skill, and slash-command affordances", "medium", "pending"]
		]);
		await this.say(session, "Here is a mock implementation plan:\n\n1. Wire initialization and capability negotiation.\n2. Render slash command suggestions from `available_commands_update`.\n3. Render model selection from `configOptions` or `_mock/list_models`.\n4. Stream plans, tool calls, usage updates, and final stop reasons.\n5. Test cancellation and permission outcomes.");
	}

	private async editScenario(session: SessionRecord, turn: ActiveTurn): Promise<void> {
		await this.tool(session, "read", "Reading app/src/mainview/App.tsx", "completed", "Located the current shell component and UI state wiring.", turn, [
			{ path: `${session.cwd}/app/src/mainview/App.tsx`, line: 1 }
		]);
		await this.tool(session, "edit", "Preparing mock UI patch", "completed", "Generated a safe diff preview. No files were actually changed by the mock server.", turn, [
			{ path: `${session.cwd}/app/src/mainview/App.tsx`, line: 12 }
		], [
			{
				type: "diff",
				path: `${session.cwd}/app/src/mainview/App.tsx`,
				oldText: "const title = \"Level5 Build\";\n",
				newText: "const title = \"Level5 Build - ACP Ready\";\n"
			}
		]);
		await this.say(session, "I simulated a code edit and attached a diff payload. Your client should show this like a real agent change preview while the repository remains untouched.");
	}

	private async testScenario(session: SessionRecord, turn: ActiveTurn): Promise<void> {
		const terminalId = this.store.nextId("terminal");
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "tool_call",
			toolCallId: this.store.nextId("tool"),
			title: "Running typecheck and tests",
			kind: "execute",
			status: "in_progress",
			content: [
				{ type: "terminal", terminalId },
				{ type: "content", content: { type: "text", text: "bunx tsc --noEmit -p tsconfig.json\nbun test" } }
			]
		});
		await this.checkpoint(turn);
		await this.usage(session, 4240, 200000, 0.006);
		await this.say(session, "Mock test run complete:\n\n- TypeScript: passed\n- Unit tests: 18 passed\n- Build smoke: passed\n\nThis is simulated terminal-style output for client rendering.");
	}

	private async webScenario(session: SessionRecord, turn: ActiveTurn): Promise<void> {
		await this.tool(session, "fetch", "Fetching current protocol reference", "completed", "Fetched ACP docs metadata and summarized relevant sections.", turn);
		await this.say(session, "I simulated a web fetch. For UI testing, treat this as a current-reference answer with source-like text, but no network was used by the mock turn.");
	}

	private async skillsScenario(session: SessionRecord, turn: ActiveTurn): Promise<void> {
		await this.tool(session, "think", "Selecting mock skills", "completed", `Available mock skills: ${mockSkills.map((skill) => skill.name).join(", ")}.`, turn);
		await this.say(session, `Mock skills available:\n\n${mockSkills.map((skill) => `- **${skill.name}**: ${skill.description}`).join("\n")}`);
	}

	private async permissionScenario(session: SessionRecord, turn: ActiveTurn): Promise<void> {
		const toolCallId = this.store.nextId("tool");
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "tool_call",
			toolCallId,
			title: "Applying protected mock edit",
			kind: "edit",
			status: "pending",
			rawInput: { reason: "exercise permission UI" }
		});
		const response = await this.requestClient("session/request_permission", {
			sessionId: session.sessionId,
			toolCall: {
				toolCallId,
				title: "Applying protected mock edit",
				kind: "edit",
				status: "pending",
				content: [{ type: "content", content: { type: "text", text: "This is a simulated protected action." } }]
			},
			options: [
				{ optionId: "allow-once", name: "Allow once", kind: "allow_once" },
				{ optionId: "allow-always", name: "Always allow mock edits", kind: "allow_always" },
				{ optionId: "reject-once", name: "Reject", kind: "reject_once" }
			]
		}, turn).catch((error) => ({ error: error.message }));
		if (turn.cancelled || selectedOutcome(response) === "cancelled") {
			this.sendSessionUpdate(session.sessionId, { sessionUpdate: "tool_call_update", toolCallId, status: "failed" });
			await this.say(session, "The permission request was cancelled, so I stopped the turn cleanly.");
			return;
		}
		if (selectedOutcome(response) === "reject-once") {
			this.sendSessionUpdate(session.sessionId, { sessionUpdate: "tool_call_update", toolCallId, status: "failed" });
			await this.say(session, "The client rejected the simulated action. I preserved the session and did not continue the edit path.");
			return;
		}
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "tool_call_update",
			toolCallId,
			status: "completed",
			content: [{ type: "content", content: { type: "text", text: "Permission granted; simulated edit completed." } }]
		});
		await this.say(session, "Permission was granted. I completed the protected mock edit and returned a normal end-turn response.");
	}

	private async tool(
		session: SessionRecord,
		kind: string,
		title: string,
		finalStatus: "completed" | "failed",
		text: string,
		turn?: ActiveTurn,
		locations?: JsonObject[],
		extraContent: JsonObject[] = []
	): Promise<void> {
		const toolCallId = this.store.nextId("tool");
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "tool_call",
			toolCallId,
			title,
			kind,
			status: "pending",
			...(locations ? { locations } : {})
		});
		await this.checkpoint(turn);
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "tool_call_update",
			toolCallId,
			status: "in_progress",
			content: [{ type: "content", content: { type: "text", text: "Working..." } }]
		});
		await this.checkpoint(turn);
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "tool_call_update",
			toolCallId,
			status: finalStatus,
			content: [{ type: "content", content: { type: "text", text } }, ...extraContent],
			...(locations ? { locations } : {})
		});
	}

	private async say(session: SessionRecord, text: string): Promise<void> {
		const messageId = this.store.nextId("message");
		const chunks = chunkText(text);
		for (const chunk of chunks) {
			this.sendSessionUpdate(session.sessionId, {
				sessionUpdate: "agent_message_chunk",
				messageId,
				content: { type: "text", text: chunk }
			});
			await this.sleep();
		}
		session.messages.push({
			role: "agent",
			messageId,
			content: [{ type: "text", text }],
			createdAt: new Date().toISOString()
		});
	}

	private async usage(session: SessionRecord, used: number, size: number, amount: number): Promise<void> {
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "usage_update",
			used,
			size,
			cost: { amount, currency: "USD" }
		});
		await this.sleep();
	}

	private sendPlan(sessionId: string, rows: Array<[string, string, string]>): void {
		this.sendSessionUpdate(sessionId, {
			sessionUpdate: "plan",
			entries: rows.map(([content, priority, status]) => ({ content, priority, status }))
		});
	}

	private sendAvailableCommands(sessionId: string): void {
		this.sendSessionUpdate(sessionId, {
			sessionUpdate: "available_commands_update",
			availableCommands: availableCommands as unknown as JsonValue
		});
	}

	private sendConfigUpdate(session: SessionRecord): void {
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "config_option_update",
			configOptions: buildConfigOptions(session.config) as unknown as JsonValue
		});
	}

	private sendSessionInfo(session: SessionRecord, title: string): void {
		this.sendSessionUpdate(session.sessionId, {
			sessionUpdate: "session_info_update",
			title,
			updatedAt: session.updatedAt,
			_meta: session._meta
		});
	}

	private sendSessionUpdate(sessionId: string, update: JsonObject): void {
		notify("session/update", { sessionId, update });
	}

	private async requestClient(method: string, params: JsonValue, turn: ActiveTurn): Promise<JsonValue> {
		const id = this.nextClientRequestId++;
		const promise = new Promise<JsonValue>((resolve, reject) => {
			this.pendingClientRequests.set(id, { resolve, reject });
		});
		writeMessage({ jsonrpc: "2.0", id, method, params });
		while (!turn.cancelled) {
			const result = await Promise.race([promise, this.sleep().then(() => Symbol.for("pending"))]);
			if (result !== Symbol.for("pending")) return result as JsonValue;
		}
		this.pendingClientRequests.delete(id);
		return { outcome: { outcome: "cancelled" } };
	}

	private applyConfig(session: SessionRecord, configId: string, value: string): void {
		const options = buildConfigOptions(session.config);
		const option = options.find((entry) => entry.id === configId);
		if (!option || !Array.isArray(option.options) || !option.options.some((entry) => asObject(entry).value === value)) {
			throw new RpcException(JsonRpcErrorCode.InvalidParams, `Invalid ${configId} value: ${value}`);
		}
		session.config[configId] = value;
		if (configId === "mode") session.modeId = value;
		session.updatedAt = new Date().toISOString();
		this.store.saveSession(session);
	}

	private updateTitleFromPrompt(session: SessionRecord, promptText: string): void {
		const title = promptText.replace(/\s+/g, " ").trim().slice(0, 64) || "Mock agent turn";
		if (!session.title || session.title === "New mock agent session") {
			session.title = title;
			session.updatedAt = new Date().toISOString();
			this.sendSessionInfo(session, title);
		}
	}

	private modeState(session: SessionRecord): JsonObject {
		return {
			currentModeId: session.modeId,
			availableModes: supportedModes as unknown as JsonValue
		};
	}

	private currentModel(params: JsonValue | undefined): string {
		const object = asObject(params ?? {});
		if (typeof object.sessionId === "string") {
			return this.getSession(object.sessionId).config.model;
		}
		return defaultConfig.model;
	}

	private models(): JsonObject[] {
		return [
			{ id: "mock-fast", name: "Mock Fast", description: "Fast deterministic responses.", contextWindow: 64000 },
			{ id: "mock-pro", name: "Mock Pro", description: "Balanced realistic agent behavior.", contextWindow: 200000 },
			{ id: "mock-deep", name: "Mock Deep", description: "Longer plans and richer update streams.", contextWindow: 1000000 }
		];
	}

	private resetSession(params: JsonValue | undefined): JsonValue {
		const object = asObject(params ?? {});
		if (typeof object.sessionId !== "string") {
			throw new RpcException(JsonRpcErrorCode.InvalidParams, "sessionId is required");
		}
		const session = this.getSession(object.sessionId);
		session.messages = [];
		session.title = "Reset mock agent session";
		session.updatedAt = new Date().toISOString();
		session._meta = { ...session._meta, messageCount: 0, resetAt: session.updatedAt };
		this.store.saveSession(session);
		this.sendSessionInfo(session, session.title);
		return {};
	}

	private requireSession(params: JsonValue | undefined): SessionRecord {
		const sessionId = String(asObject(params).sessionId ?? "");
		return this.getSession(sessionId);
	}

	private getSession(sessionId: string): SessionRecord {
		const session = this.store.snapshot.sessions[sessionId];
		if (!session || session.deleted) {
			throw new RpcException(JsonRpcErrorCode.InvalidParams, `Unknown session: ${sessionId}`);
		}
		return session;
	}

	private requireAuth(): void {
		if (!this.authenticated) {
			throw new RpcException(authRequiredError.code, authRequiredError.message);
		}
	}

	private async checkpoint(turn?: ActiveTurn): Promise<void> {
		await this.sleep();
		if (turn?.cancelled) {
			throw new CancelledTurn();
		}
	}

	private sleep(): Promise<void> {
		return new Promise((resolve) => setTimeout(resolve, Math.max(0, this.delayMs)));
	}
}

class CancelledTurn extends Error {}

export async function runServer(server: AcpMockServer): Promise<void> {
	let buffer = "";
	for await (const chunk of Bun.stdin.stream()) {
		buffer += new TextDecoder().decode(chunk);
		while (buffer.includes("\n")) {
			const index = buffer.indexOf("\n");
			const line = buffer.slice(0, index).trim();
			buffer = buffer.slice(index + 1);
			if (line.length > 0) await server.handleLine(line);
		}
	}
	if (process.env.ACP_MOCK_KEEPALIVE === "1") {
		await new Promise(() => undefined);
	}
}

function asObject(value: JsonValue | undefined): JsonObject {
	if (!value || typeof value !== "object" || Array.isArray(value)) return {};
	return value as JsonObject;
}

function asStringArray(value: JsonValue): string[] {
	return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : [];
}

function requireAbsolutePath(path: string, field: string): string {
	if (!path.startsWith("/")) {
		throw new RpcException(JsonRpcErrorCode.InvalidParams, `${field} must be an absolute path`);
	}
	return path;
}

function normalizePrompt(value: JsonValue | undefined): ContentBlock[] {
	if (!Array.isArray(value)) {
		throw new RpcException(JsonRpcErrorCode.InvalidParams, "prompt must be an array");
	}
	return value.map((entry) => {
		const object = asObject(entry);
		if (object.type === "text" && typeof object.text === "string") return { type: "text", text: object.text };
		return entry as unknown as ContentBlock;
	});
}

function contentToText(content: ContentBlock): string {
	if (content.type === "text") return content.text;
	if (content.type === "resource_link") return `${content.name} ${content.uri}`;
	if (content.type === "resource") return content.resource.text ?? content.resource.uri;
	if (content.type === "image") return `[image:${content.mimeType}]`;
	if (content.type === "audio") return `[audio:${content.mimeType}]`;
	return "";
}

function chunkText(text: string): string[] {
	if (text.length <= 140) return [text];
	const chunks: string[] = [];
	for (let index = 0; index < text.length; index += 140) {
		chunks.push(text.slice(index, index + 140));
	}
	return chunks;
}

function selectedOutcome(value: JsonValue): string | undefined {
	const object = asObject(value);
	const outcome = asObject(object.outcome);
	if (outcome.outcome === "cancelled") return "cancelled";
	if (typeof outcome.optionId === "string") return outcome.optionId;
	return undefined;
}
