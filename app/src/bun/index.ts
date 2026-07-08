import { homedir } from "node:os";
import Electrobun, { ApplicationMenu, BrowserWindow, BrowserView, Updater, Utils } from "electrobun/bun";
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
	OMP_MISSING_CLI_MESSAGE,
	SETTINGS_KEY_ACP_PROVIDER,
	buildAgentSpawnOptions,
	buildSelectedPermissionResponse,
	devinPermissionMode,
	isDevinAvailable,
	isOmpAvailable,
	normalizeAcpProvider,
	selectedAgentBackend,
	normalizeApprovalMode,
	pickAutoApproveOptionId,
	resolveAgentCwd,
	shouldPersistSessionInfoUpdate,
} from "./agent/runtime";
import { getProjectGitStatus } from "./git/status";
import { getFileDiffPreview, getProjectReviewSnapshot } from "./git/review";
import { applyMacWindowEffects } from "./macWindowEffects";
import { openDatabase } from "./persistence/database";
import { getSetting, setSetting } from "./persistence/settingsStore";
import { listRecentProjects as listRecentProjectsStore, upsertSelectedFolder } from "./persistence/recentProjectStore";
import {
	deleteSession as deletePersistedSession,
	fetchTranscriptItems,
	fetchTranscriptState,
	hiddenSessionIds,
	listAllSessionRows,
	markSessionHidden,
	upsertSessionRow,
	upsertTranscriptItems,
	upsertTranscriptState,
} from "./persistence/sessionStore";
import {
	countMessages,
	hydrateTranscript,
	snapshotTranscriptForPersistence,
	toPersistedSessionRow,
	toSessionSummary,
} from "./persistence/sessionSync";
import { APPROVAL_MODE_LABELS } from "../shared/rpc";
import type {
	AppRPC,
	AcpProviderId,
	ApprovalModeId,
	AgentRunStatus,
	CancelAgentPromptParams,
	DeleteAgentSessionParams,
	GetFileDiffPreviewParams,
	GetProjectGitStatusParams,
	GetProjectReviewSnapshotParams,
	DeleteAgentSessionResponse,
	GetSessionTranscriptParams,
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
	RecentProjectSummary,
	RespondToAgentPermissionParams,
	StartAgentPromptParams,
	StartAgentPromptResponse,
} from "../shared/rpc";
import type { ElectrobunEvent } from "electrobun/bun";

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

function sendAgentUpdate(sessionId: string, update: AgentUpdate) {
	rpc.send.agentUpdate({ sessionId, update });
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

/**
 * Shared, cross-project state: the durable local cache (sessions,
 * transcripts, hidden-session markers) and the push channel back to the
 * renderer. Every `ProjectAgentConnection` reads/writes through this rather
 * than owning its own copy, since the sidebar is a single global list
 * spanning every project at once (see AGENTS.md).
 */
class AgentRuntimeContext {
	// Durable local cache: same ~/.level5build/level5.sqlite path and schema
	// shape as the native app's SessionPersistenceStore, so sessions and
	// transcripts survive a relaunch without needing a live agent process.
	readonly db = openDatabase();
	readonly hiddenIds: Set<string>;
	readonly sessions = new Map<string, AgentSessionSummary>();
	readonly transcripts = new Map<string, AgentUpdate[]>();
	// Sessions whose most recent turn was manually cancelled: late
	// session/update notifications for that turn (which can still arrive
	// after session/cancel is sent) are dropped rather than applied, so
	// stale output can never leak into an immediate re-prompt. Cleared
	// synchronously the moment the NEXT startPrompt call resolves a real
	// session id for this session (see startPrompt), not by waiting for a
	// `user_message_chunk` echo -- real Devin/omp has been observed to
	// never send that echo at all, so waiting for it left staleness stuck
	// forever on non-mock backends. This is safe without a leak window:
	// `isProjectRunning`/`this.running` blocks any resend at the RPC
	// boundary until the CANCELLED turn's own `session/prompt` request
	// promise has fully settled (either the backend responds after
	// processing the cancel, or `forceStopActiveTurn`'s hard reset
	// synchronously kills the process and fails that pending promise) --
	// and the transport parses stdout strictly line-by-line in arrival
	// order, so every trailing notification for the cancelled turn is
	// guaranteed to have already reached `handleNotification` before
	// `running` can flip back to false and unblock a resend.
	readonly staleSessionIds = new Set<string>();
	acpProvider: AcpProviderId;

	constructor(private readonly emitUpdate: (sessionId: string, update: AgentUpdate) => void) {
		this.hiddenIds = hiddenSessionIds(this.db);
		this.acpProvider = normalizeAcpProvider(getSetting(this.db, SETTINGS_KEY_ACP_PROVIDER));
		this.hydratePersistedSessions();
	}

	setAcpProvider(provider: AcpProviderId): void {
		this.acpProvider = provider;
		setSetting(this.db, SETTINGS_KEY_ACP_PROVIDER, provider);
	}

	/**
	 * Loads every durably cached session and its transcript into memory
	 * before any process connects or any RPC is served, so the sidebar has
	 * content immediately on a fresh launch.
	 */
	private hydratePersistedSessions(): void {
		for (const row of listAllSessionRows(this.db)) {
			if (this.hiddenIds.has(row.sessionId)) {
				continue;
			}
			const items = fetchTranscriptItems(this.db, row.sessionId);
			const state = fetchTranscriptState(this.db, row.sessionId);
			const transcript = hydrateTranscript(items, state);
			this.transcripts.set(row.sessionId, transcript);
			this.sessions.set(row.sessionId, toSessionSummary(row, countMessages(transcript)));
		}
	}

	emit(sessionId: string, update: AgentUpdate): void {
		this.emitUpdate(sessionId, update);
	}

	/** A project's key is its normalized cwd; a synthetic home-directory key covers the no-project fallback. */
	projectKeyFor(cwd: string | null | undefined): string {
		return resolveAgentCwd(cwd);
	}

	/**
	 * A session the user deleted locally must never resurrect from a
	 * backend that doesn't (or can't) forget it server-side -- e.g. a
	 * `session_info_update` notification or a `session/list` reconciliation
	 * result for an already-hidden id. Every path that could otherwise
	 * revive a row runs through this method, so the hidden-set check here
	 * covers all of them.
	 */
	rememberSession(
		session: AgentSessionSummary,
		options: { shouldEmit?: boolean; fallbackCwd?: string | null } = {},
	): AgentSessionSummary {
		const { shouldEmit = true, fallbackCwd = null } = options;
		if (this.hiddenIds.has(session.sessionId)) {
			return session;
		}
		const existing = this.sessions.get(session.sessionId);
		const nextSession = {
			...existing,
			...session,
			title: session.title.trim() || existing?.title || "New chat",
			cwd: session.cwd || existing?.cwd || fallbackCwd || homedir(),
			updatedAt: session.updatedAt || existing?.updatedAt || new Date().toISOString(),
			messageCount: session.messageCount || existing?.messageCount || 0,
		};
		this.sessions.set(session.sessionId, nextSession);
		upsertSessionRow(this.db, toPersistedSessionRow(nextSession, selectedAgentBackend()));
		if (shouldEmit) {
			this.emit(session.sessionId, { kind: "session", session: nextSession });
		}
		return nextSession;
	}

	sortedSessions(): AgentSessionSummary[] {
		return [...this.sessions.values()].sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
	}

	rememberTranscriptUpdate(sessionId: string, update: AgentUpdate): void {
		if (!sessionId || this.hiddenIds.has(sessionId)) {
			return;
		}
		const current = this.transcripts.get(sessionId) ?? [];
		const next = upsertTranscriptUpdate(current, update);
		this.transcripts.set(sessionId, next);
		const snapshot = snapshotTranscriptForPersistence(next);
		upsertTranscriptItems(this.db, sessionId, snapshot.items);
		upsertTranscriptState(this.db, sessionId, snapshot.state);
	}

	emitTranscriptUpdate(sessionId: string, update: AgentUpdate): void {
		this.rememberTranscriptUpdate(sessionId, update);
		this.emit(sessionId, update);
	}

	replayTranscript(sessionId: string): void {
		const transcript = this.transcripts.get(sessionId);
		if (!transcript) {
			return;
		}
		for (const update of transcript) {
			this.emit(sessionId, update);
		}
	}

	/**
	 * Deletion never requires the backend's agreement: some backends (real
	 * Devin) don't implement `session/delete` at all. Local removal plus
	 * the durable hidden-session marker happen unconditionally so a session
	 * the user deleted locally stays gone even if the ACP server keeps
	 * reporting it, and even across a relaunch.
	 */
	deleteSessionEverywhere(sessionId: string): void {
		this.sessions.delete(sessionId);
		this.transcripts.delete(sessionId);
		this.staleSessionIds.delete(sessionId);
		deletePersistedSession(this.db, sessionId);
		markSessionHidden(this.db, sessionId, Date.now());
		this.hiddenIds.add(sessionId);
	}
}

/**
 * One spawned ACP backend process (`devin`, `omp`, or the mock server) per
 * project directory, keyed by normalized project path (see AGENTS.md). Owns
 * its own process/transport/ACP client, turn/permission state, config, and
 * slash commands, so one project's process exiting, timing out, or
 * streaming events cannot leak into another project's transcript. The
 * durable cache (sessions/transcripts/hidden ids) is shared cross-project
 * state owned by `AgentRuntimeContext`, not duplicated here.
 */
class ProjectAgentConnection {
	private process: Bun.PipedSubprocess | null = null;
	private stdin: Bun.PipedSubprocess["stdin"] | null = null;
	private transport: AcpJsonRpcTransport | null = null;
	private acp: AcpClient | null = null;
	private readonly permissionRequests = new Map<RpcId, AgentPermissionRequest>();
	private turnWatchdog: AcpTurnIdleWatchdog | null = null;
	private initialized = false;
	private sessionId: string | null = null;
	private currentCwd: string | null = null;
	// True once the current `sessionId` has been written to the durable
	// cache/sidebar via persistCurrentSession. A session created only for
	// warm-up (composer priming on project selection, or the eager
	// home-directory prime) stays false -- and invisible in the sidebar --
	// until an actual send flips it, even if that send reuses this exact
	// same in-memory session.
	private sessionPersisted = false;
	private processCwd: string | null = null;
	private processPermissionMode: string | null = null;
	private running = false;
	private cancellationRequested = false;
	private approvalMode: ApprovalModeId = DEFAULT_APPROVAL_MODE;
	private configOptions: AgentConfigOption[] = [];
	private slashCommands: AgentSlashCommand[] = [];
	// Every session this connection's process has created or primed
	// (session/new, session/load, session/resume): needed for close-before-
	// kill teardown, since real Devin refuses a future session/load for a
	// session still held open by a live process.
	private readonly primedSessionIds = new Set<string>();
	// Set only while a send-time session/load or session/resume priming
	// call is in flight, so handleNotification can unconditionally drop
	// that call's replay side effect (see primeSession).
	private primingSessionId: string | null = null;
	// Serializes every operation that can spawn/initialize this
	// connection's process or create/load/resume a session
	// (startPrompt/prepareSession/bestEffortDeleteSession's "ensure ready"
	// phase). Real Devin's ACP server does not handle a session/new racing
	// an unrelated session/load or session/prompt safely against the same
	// live process -- e.g. a composer-priming prepareSession() call (on
	// project selection) racing a startPrompt() for the same project could
	// otherwise issue two concurrent initialize/session-new calls before
	// either sets this.initialized/this.sessionId. Mirrors native's
	// AgentSessionModel.awaitComposerPriming/primingTaskByProjectKey (see
	// AGENTS.md), just implemented as a per-connection async lock instead
	// of an explicit task-by-key map, since a connection already is scoped
	// to one project.
	private connectionSetupChain: Promise<void> = Promise.resolve();

	private withConnectionSetupLock<T>(fn: () => Promise<T>): Promise<T> {
		const ready = this.connectionSetupChain.catch(() => undefined);
		const result = ready.then(fn);
		this.connectionSetupChain = result.then(
			() => undefined,
			() => undefined,
		);
		return result;
	}

	constructor(
		readonly projectKey: string,
		private readonly runtime: AgentRuntimeContext,
	) {}

	get isRunning() {
		return this.running;
	}

	isRunningSession(sessionId: string): boolean {
		return this.running && this.sessionId === sessionId;
	}

	async startPrompt(params: StartAgentPromptParams, cwd: string): Promise<void> {
		this.running = true;
		this.cancellationRequested = false;
		this.approvalMode = normalizeApprovalMode(params.approvalMode);
		this.emitStatus("starting", cwd);

		try {
			await this.withConnectionSetupLock(async () => {
				await this.ensureProcess(cwd);
				await this.ensureInitialized();
				if (params.sessionId) {
					await this.primeSession(params.sessionId, cwd);
					// A prepared New Chat already has a session id in the
					// renderer, but it is intentionally absent from SQLite
					// until the first real send. Persist it before
					// session/prompt can stream transcript rows that foreign-key
					// to sessions.
					this.persistCurrentSession(cwd);
				} else {
					// An actual send: persist now, even if this reuses an
					// unpersisted warm-up session from prepareSession/the
					// eager home-directory prime.
					await this.ensureSession(cwd, { persist: true });
				}
			});
			if (!this.sessionId) {
				throw new Error("Agent session was not created.");
			}
			const sessionId = this.sessionId;
			// A fresh send un-sticks staleness for this session, even if the
			// previous turn was cancelled -- safe without a leak window; see
			// the staleSessionIds field comment above for why. Done here
			// (synchronously, before session/prompt is even dispatched)
			// rather than waiting on a `user_message_chunk` echo -- see
			// handleNotification's dropped echo handling below for why that
			// echo can no longer be trusted.
			this.runtime.staleSessionIds.delete(sessionId);
			// The backend is the sole source of truth for the user's own
			// prompt landing in the durable transcript -- it must not depend
			// on the ACP process echoing it back as `user_message_chunk`.
			// Real Devin/omp has been observed to never send that echo at
			// all (only the mock server always does), which previously left
			// every persisted session missing its own opening question:
			// nothing ever wrote a `kind: "message", role: "user"` row to
			// SQLite, so it vanished the moment the app relaunched even
			// though it was visible all session long via the renderer's
			// purely-local optimistic bubble (see dispatchPrompt/
			// optimisticUserTextRef in App.tsx). That optimistic bubble's
			// own text-match dedup already treats this synthesized update
			// exactly like it used to treat a live echo, so no frontend
			// change is required.
			this.runtime.emitTranscriptUpdate(sessionId, {
				kind: "message",
				role: "user",
				messageId: crypto.randomUUID(),
				content: { type: "text", text: params.prompt },
			});

			if (params.model && this.configOptions.some((option) => option.id === "model")) {
				await this.requireAcp().setConfigOption({
					sessionId,
					configId: "model",
					value: params.model,
				});
			}

			this.emitStatus("running", cwd);
			this.startTurnWatchdog();
			const result = asObject(
				await this.requireAcp().prompt({
					sessionId,
					prompt: buildPromptContent(params.prompt, params.attachments),
				}),
			);
			if (this.cancellationRequested) {
				this.runtime.emit(sessionId, { kind: "stop", stopReason: "cancelled" });
				this.emitStatus("completed", cwd);
				return;
			}
			const existingSession = this.runtime.sessions.get(sessionId);
			if (existingSession) {
				this.runtime.rememberSession({
					...existingSession,
					updatedAt: new Date().toISOString(),
					messageCount: existingSession.messageCount + 1,
				});
			}
			this.runtime.emit(sessionId, { kind: "stop", stopReason: asString(result.stopReason, "end_turn") });
			this.emitStatus("completed", cwd);
		} catch (error) {
			if (this.cancellationRequested) {
				this.runtime.emit(this.sessionId ?? "", { kind: "stop", stopReason: "cancelled" });
				this.emitStatus("completed", cwd);
				return;
			}
			this.runtime.emit(this.sessionId ?? "", {
				kind: "error",
				message: error instanceof Error ? error.message : "Agent request failed.",
			});
			this.emitStatus("error", cwd);
		} finally {
			this.stopTurnWatchdog();
			this.running = false;
		}
	}

	cancelActiveTurn(sessionId: string): boolean {
		if (!this.running || this.sessionId !== sessionId) {
			return false;
		}
		this.cancellationRequested = true;
		this.runtime.staleSessionIds.add(sessionId);
		this.turnWatchdog?.setAwaitingHuman(false);
		this.turnWatchdog?.touch();
		this.requireAcp().cancel({ sessionId });
		for (const requestId of this.permissionRequests.keys()) {
			this.requireAcp().respondSuccess(requestId, { outcome: { outcome: "cancelled" } });
		}
		this.permissionRequests.clear();
		this.runtime.emit(sessionId, { kind: "status", status: "stopping", cwd: this.currentCwd ?? undefined, sessionId });
		return true;
	}

	respondToPermission(requestId: RpcId, optionId: string): boolean {
		if (!this.permissionRequests.has(requestId)) {
			return false;
		}
		this.permissionRequests.delete(requestId);
		this.turnWatchdog?.setAwaitingHuman(false);
		this.turnWatchdog?.touch();
		this.requireAcp().respondSuccess(requestId, buildSelectedPermissionResponse(optionId));
		return true;
	}

	listSlashCommands(): AgentSlashCommand[] {
		return this.slashCommands;
	}

	listConfigOptions(): AgentConfigOption[] {
		return this.configOptions;
	}

	/**
	 * Lets a caller (AgentAcpClient's pull-based listConfigOptions/
	 * listSlashCommands) wait for whatever ensureProcess/ensureInitialized/
	 * ensureSession setup is currently in flight -- or already finished --
	 * on this connection, without itself joining the mutual-exclusion
	 * queue (see withConnectionSetupLock). A pure read-only wait: against
	 * a real backend (devin/omp), the eager home-directory/project warm-up
	 * at module bottom is fire-and-forget, so a one-shot snapshot read of
	 * configOptions/slashCommands taken the instant the webview mounts
	 * loses the race against the real subprocess spawn + initialize +
	 * session/new handshake (measured 0.6-3s+ for real omp/devin, versus
	 * near-0ms for the mock server) every single time. Resolves once that
	 * in-flight setup settles, or immediately if none is pending. Bounded
	 * by the ACP transport's own per-request timeout
	 * (ACP_REQUEST_TIMEOUTS_MS.setup, 15s) rather than hanging
	 * indefinitely if the backend itself is unresponsive -- though a
	 * queued chain of setup steps that each individually time out (e.g.
	 * ensureProcess -> ensureInitialized -> ensureSession all stalling)
	 * can still stack up to tens of seconds before this resolves. That's
	 * an acceptable tradeoff, not a hang: the only caller
	 * (listConfigOptions/listSlashCommands) is invoked by the frontend's
	 * fire-and-forget refreshComposerMenuData (never awaited by anything
	 * blocking), and the RPC transport's own maxRequestTime is minutes,
	 * not seconds.
	 */
	awaitSetup(): Promise<void> {
		return this.connectionSetupChain.catch(() => undefined);
	}

	async prepareSession(params: PrepareAgentSessionParams, cwd: string): Promise<PrepareAgentSessionResponse> {
		if (this.running) {
			return { prepared: false, reason: "Wait for the active agent turn to finish before switching projects." };
		}
		this.approvalMode = normalizeApprovalMode(params.approvalMode);
		try {
			await this.withConnectionSetupLock(async () => {
				await this.ensureProcess(cwd);
				await this.ensureInitialized();
				// Warm-up only (composer priming on project selection, or
				// the eager home-directory prime): creates an in-memory ACP
				// session so model config/slash commands are available
				// immediately, but must not persist/appear in the sidebar
				// until the user actually sends a first message.
				await this.ensureSession(cwd, { persist: false });
			});
			this.runtime.emit(this.sessionId ?? "", { kind: "status", status: "idle", cwd, sessionId: this.sessionId ?? undefined });
			return { prepared: true, sessionId: this.sessionId ?? undefined };
		} catch (error) {
			return { prepared: false, reason: error instanceof Error ? error.message : "Failed to prepare agent session." };
		}
	}

	/**
	 * Send-time priming for an existing, already-known session: the first
	 * time this process run sends into a session it has not already
	 * created or primed, session/load (or session/resume if a cached
	 * transcript exists) brings server-side context back before
	 * session/prompt. Any session/update replay that triggers is
	 * unconditionally suppressed in handleNotification -- it is a
	 * context-loading side effect, not a way to repaint history; the
	 * renderer already has the cached transcript via getSessionTranscript.
	 * A session already created or primed earlier in this same process run
	 * is sent to directly, with no repeated session/load. Selecting a
	 * session in the sidebar never calls this -- only actually sending
	 * into it does.
	 */
	private async primeSession(sessionId: string, cwd: string): Promise<void> {
		if (this.sessionId === sessionId) {
			return;
		}
		if (this.sessionId && this.sessionId !== sessionId) {
			await this.requireAcp().closeSession({ sessionId: this.sessionId }).catch(() => undefined);
			this.primedSessionIds.delete(this.sessionId);
			this.sessionId = null;
			this.currentCwd = null;
			this.sessionPersisted = false;
		}

		const cachedTranscript = this.runtime.transcripts.get(sessionId);
		const acp = this.requireAcp();
		const sessionParams = { sessionId, cwd, mcpServers: [] };
		this.primingSessionId = sessionId;
		try {
			const result = asObject(
				await (cachedTranscript ? acp.resumeSession(sessionParams) : acp.loadSession(sessionParams)),
			);
			this.emitConfig(result.configOptions);
		} finally {
			this.primingSessionId = null;
		}
		this.sessionId = sessionId;
		this.currentCwd = cwd;
		this.primedSessionIds.add(sessionId);
	}

	/** Best-effort ACP `session/delete` against this connection's process; local/durable removal is the caller's job. */
	async bestEffortDeleteSession(sessionId: string, cwd: string): Promise<void> {
		try {
			await this.withConnectionSetupLock(async () => {
				await this.ensureProcess(cwd);
				await this.ensureInitialized();
			});
			await this.requireAcp().deleteSession({ sessionId });
		} catch {
			// Best-effort only; local removal happens regardless in the caller.
		} finally {
			this.permissionRequests.clear();
			this.primedSessionIds.delete(sessionId);
			if (this.sessionId === sessionId) {
				this.sessionId = null;
				this.currentCwd = null;
				this.runtime.emit(sessionId, { kind: "status", status: "idle" });
			}
		}
	}

	async startNewChat(): Promise<boolean> {
		if (this.running) {
			return false;
		}
		this.permissionRequests.clear();
		const previousSessionId = this.sessionId;
		if (this.sessionId) {
			await this.requireAcp().closeSession({ sessionId: this.sessionId }).catch(() => undefined);
			this.primedSessionIds.delete(this.sessionId);
		}
		this.sessionId = null;
		this.currentCwd = null;
		this.runtime.emit(previousSessionId ?? "", { kind: "status", status: "idle" });
		return true;
	}

	/**
	 * Best-effort `session/close` for every session this process created or
	 * primed, before the caller kills the process. Real Devin refuses a
	 * future `session/load` for a session still held open by a live
	 * process ("already open in another process"), so simply killing the
	 * process without this handshake would permanently orphan every
	 * session it had open -- including from this process's own next
	 * relaunch.
	 */
	private async closeAllSessions(): Promise<void> {
		const acp = this.acp;
		if (!acp) {
			return;
		}
		for (const sessionId of this.primedSessionIds) {
			await acp.closeSession({ sessionId }).catch(() => undefined);
		}
		this.primedSessionIds.clear();
	}

	/** Approval-mode restarts and app teardown both route through here: close-before-kill, then hard reset. */
	async reset(): Promise<void> {
		await this.closeAllSessions();
		this.hardReset();
	}

	private hardReset(): void {
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
		const previousSessionId = this.sessionId;
		this.sessionId = null;
		this.currentCwd = null;
		this.processCwd = null;
		this.processPermissionMode = null;
		this.cancellationRequested = false;
		this.approvalMode = DEFAULT_APPROVAL_MODE;
		this.configOptions = [];
		this.slashCommands = [];
		// A dead connection can never deliver the late output staleness
		// exists to guard against, and can never deliver the echo that
		// would clear it either; stale tracking is connection-scoped.
		if (previousSessionId) {
			this.runtime.staleSessionIds.delete(previousSessionId);
		}
		this.runtime.emit(previousSessionId ?? "", { kind: "status", status: "idle" });
	}

	private async ensureProcess(cwd: string): Promise<void> {
		const backend = selectedAgentBackend(process.env, this.runtime.acpProvider);
		const permissionMode = backend === "devin" ? devinPermissionMode(this.approvalMode) : backend;
		const spawnFailureMessage =
			backend === "mock" ? ACP_MOCK_SPAWN_FAILURE_MESSAGE : backend === "omp" ? OMP_MISSING_CLI_MESSAGE : DEVIN_MISSING_CLI_MESSAGE;
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
			if (backend === "omp" && !isOmpAvailable()) {
				throw new AcpError("spawn_failure", OMP_MISSING_CLI_MESSAGE);
			}
			const options = buildAgentSpawnOptions({ approvalMode: this.approvalMode, cwd, provider: this.runtime.acpProvider });
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
					this.runtime.emit(this.sessionId ?? "", { kind: "error", message: error.message });
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

	/**
	 * Creates (or reuses) an ACP session for `cwd`. `persist` controls
	 * whether it's remembered to the durable cache/sidebar: a New Chat --
	 * including the eager home-directory/project warm-up that primes model
	 * config and slash commands before the user has typed anything (see
	 * `prepareSession` and the eager priming call in the module bottom) --
	 * must create no sidebar row and write nothing to SQLite until the
	 * user actually sends a first message (mirrors native's
	 * AgentSessionModel: "New Chat is only an unsent draft... appears in
	 * no sidebar row until first send", see AGENTS.md).
	 */
	private async ensureSession(cwd: string, options: { persist: boolean }): Promise<void> {
		if (this.sessionId && this.currentCwd === cwd) {
			if (options.persist) {
				this.persistCurrentSession(cwd);
			}
			return;
		}
		if (this.sessionId && this.currentCwd !== cwd) {
			await this.requireAcp().closeSession({ sessionId: this.sessionId }).catch(() => undefined);
			this.primedSessionIds.delete(this.sessionId);
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
		this.sessionPersisted = false;
		this.primedSessionIds.add(sessionId);
		if (options.persist) {
			this.persistCurrentSession(cwd);
		}
		this.runtime.emit(sessionId, { kind: "status", status: "starting", sessionId, cwd });
		this.emitConfig(result.configOptions);
	}

	private persistCurrentSession(cwd: string): void {
		if (!this.sessionId || this.sessionPersisted) {
			return;
		}
		this.sessionPersisted = true;
		this.runtime.rememberSession(
			{
				sessionId: this.sessionId,
				title: "New chat",
				cwd,
				updatedAt: new Date().toISOString(),
				messageCount: 0,
			},
			{ fallbackCwd: cwd },
		);
	}

	private emitStatus(status: AgentRunStatus, cwd?: string): void {
		this.runtime.emit(this.sessionId ?? "", { kind: "status", status, cwd, sessionId: this.sessionId ?? undefined });
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
		if (sessionId) {
			this.runtime.staleSessionIds.delete(sessionId);
		}
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
			this.runtime.emit(this.sessionId ?? "", {
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
		const sessionId = asString(params.sessionId, this.sessionId ?? "");

		if (this.approvalMode !== "ask") {
			const autoOptionId = pickAutoApproveOptionId(options);
			if (autoOptionId) {
				this.requireAcp().respondSuccess(message.id, buildSelectedPermissionResponse(autoOptionId));
				this.runtime.emit(sessionId, {
					kind: "info",
					id: String(message.id),
					message: `Auto-approved "${toolCall.title}" (${APPROVAL_MODE_LABELS[this.approvalMode]} mode).`,
				});
				return;
			}
		}

		const request: AgentPermissionRequest = {
			requestId: message.id ?? "",
			sessionId,
			toolCall,
			options,
		};
		this.permissionRequests.set(message.id, request);
		this.turnWatchdog?.setAwaitingHuman(true);
		this.runtime.emit(sessionId, { kind: "permission", request });
	}

	private handleNotification(message: AcpNotification): void {
		if (message.method !== CLIENT_METHODS.session_update) {
			return;
		}
		const params = asObject(message.params);
		const update = asObject(params.update);
		const updateType = asString(update.sessionUpdate);
		const sessionId = asString(params.sessionId, this.sessionId ?? "");

		if (
			sessionId === this.primingSessionId &&
			(updateType === "user_message_chunk" ||
				updateType === "agent_message_chunk" ||
				updateType === "agent_thought_chunk" ||
				updateType === "plan" ||
				updateType === "tool_call" ||
				updateType === "tool_call_update" ||
				updateType === "usage_update")
		) {
			// session/load's/session/resume's replay is a context-loading
			// side effect, not a way to repaint history -- the renderer
			// already has this session's cached transcript. Unconditionally
			// suppressed regardless of staleness.
			return;
		}

		if (this.runtime.staleSessionIds.has(sessionId)) {
			// Late output from an already-cancelled turn: drop it entirely
			// (not just skip rendering) so it can never leak into an
			// immediate re-prompt in the same session. Un-sticking now
			// happens at the authoritative send point in startPrompt --
			// synchronously before session/prompt is even dispatched --
			// rather than waiting for a `user_message_chunk` echo that real
			// Devin/omp has been observed to never send.
			return;
		}

		if (updateType === "user_message_chunk") {
			// Never persisted from here: startPrompt already wrote the
			// authoritative `kind: "message", role: "user"` entry at send
			// time (see its comment). Treating this live echo the same way
			// would either duplicate that entry (contiguous-merge in
			// upsertTranscriptUpdate) or race it, depending on arrival
			// order.
			return;
		}
		if (updateType === "agent_message_chunk") {
			this.runtime.emitTranscriptUpdate(sessionId, {
				kind: "message",
				role: "agent",
				messageId: asString(update.messageId),
				content: normalizeContent(update.content),
			});
			return;
		}
		if (updateType === "agent_thought_chunk") {
			this.runtime.emitTranscriptUpdate(sessionId, {
				kind: "thought",
				messageId: asString(update.messageId),
				content: normalizeContent(update.content),
			});
			return;
		}
		if (updateType === "plan") {
			this.runtime.emitTranscriptUpdate(sessionId, {
				kind: "plan",
				items: Array.isArray(update.entries) ? update.entries.map(normalizePlanItem) : [],
			});
			return;
		}
		if (updateType === "tool_call") {
			this.runtime.emitTranscriptUpdate(sessionId, { kind: "tool", tool: normalizeToolCall(update, { isUpdate: false }) });
			return;
		}
		if (updateType === "tool_call_update") {
			this.runtime.emitTranscriptUpdate(sessionId, { kind: "tool", tool: normalizeToolCall(update, { isUpdate: true }) });
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
			this.runtime.emit(sessionId, { kind: "slashCommands", commands: this.slashCommands });
			return;
		}
		if (updateType === "usage_update") {
			this.runtime.emitTranscriptUpdate(sessionId, {
				kind: "usage",
				used: asNumber(update.used),
				size: asNumber(update.size, 1),
			});
			return;
		}
		if (updateType === "session_info_update") {
			// A session created only for warm-up (composer priming on
			// project selection, or the eager home-directory prime) must
			// stay invisible in the sidebar/DB until an actual send flips
			// sessionPersisted (see persistCurrentSession) -- otherwise a
			// backend that fires session_info_update right after
			// session/new (e.g. the mock server's post-create timer, and
			// plausibly real Devin too) would write an unsent "New chat"
			// row to SQLite before the user ever typed anything.
			if (
				!shouldPersistSessionInfoUpdate({
					sessionId,
					currentSessionId: this.sessionId,
					sessionPersisted: this.sessionPersisted,
				})
			) {
				return;
			}
			this.runtime.rememberSession(
				normalizeSessionSummary({
					sessionId,
					cwd: this.currentCwd ?? "",
					title: update.title,
					updatedAt: update.updatedAt,
					_meta: update._meta,
				}),
				{ fallbackCwd: this.currentCwd },
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
		this.runtime.emit(this.sessionId ?? "", {
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
		const sessionId = this.sessionId;
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
			this.runtime.emit(sessionId ?? "", { kind: "error", message: `Agent ACP process exited with code ${exitCode}.` });
		}
	}
}

/**
 * Thin per-project dispatcher. Owns the shared `AgentRuntimeContext` and a
 * `Map<projectKey, ProjectAgentConnection>`, giving true concurrent sessions
 * across different projects: each project's connection has its own process,
 * event stream, and turn/permission state (see AGENTS.md). Within a single
 * project, behavior is unchanged from before this pool existed: one process,
 * one active turn at a time.
 */
class AgentAcpClient {
	private readonly runtime: AgentRuntimeContext;
	private readonly connections = new Map<string, ProjectAgentConnection>();
	// Tracks whichever project's connection most recently had a
	// composer-facing action (prepareSession/startPrompt/loadSession), so
	// RPCs that don't carry explicit project context (listSlashCommands,
	// listSkills, startNewChat) have a reasonable target. This mirrors the
	// pre-pool behavior, where there was only ever one connection to ask.
	private lastActiveProjectKey: string | null = null;

	constructor(emit: (sessionId: string, update: AgentUpdate) => void) {
		this.runtime = new AgentRuntimeContext(emit);
	}

	private connectionFor(projectKey: string): ProjectAgentConnection {
		let connection = this.connections.get(projectKey);
		if (!connection) {
			connection = new ProjectAgentConnection(projectKey, this.runtime);
			this.connections.set(projectKey, connection);
		}
		return connection;
	}

	isProjectRunning(cwd: string | null | undefined): boolean {
		const projectKey = this.runtime.projectKeyFor(cwd);
		return this.connections.get(projectKey)?.isRunning ?? false;
	}

	async startPrompt(params: StartAgentPromptParams): Promise<void> {
		const cwd = resolveAgentCwd(params.cwd);
		const projectKey = this.runtime.projectKeyFor(cwd);
		const connection = this.connectionFor(projectKey);
		if (connection.isRunning) {
			this.runtime.emit("", { kind: "error", message: "An agent turn is already running." });
			return;
		}
		this.lastActiveProjectKey = projectKey;
		await connection.startPrompt(params, cwd);
	}

	cancelActiveTurn(sessionId: string): boolean {
		const session = this.runtime.sessions.get(sessionId);
		if (!session) {
			return false;
		}
		const projectKey = this.runtime.projectKeyFor(session.cwd);
		return this.connections.get(projectKey)?.cancelActiveTurn(sessionId) ?? false;
	}

	respondToPermission({ requestId, optionId, sessionId }: RespondToAgentPermissionParams): boolean {
		const session = this.runtime.sessions.get(sessionId);
		if (!session) {
			return false;
		}
		const projectKey = this.runtime.projectKeyFor(session.cwd);
		return this.connections.get(projectKey)?.respondToPermission(requestId, optionId) ?? false;
	}

	/**
	 * The durable local cache (already hydrated at construction) is the
	 * ONLY source: there is no ACP `session/list` call anywhere in this
	 * class, matching native's AgentSessionModel (see AGENTS.md -- "There
	 * is no ACP session/list call anywhere... the sidebar is sourced
	 * entirely from SessionPersistenceStore"). A backend's own session
	 * history (e.g. real Devin's full session list across every project
	 * that has ever used it, not just this app's local cache) must never
	 * bleed into the sidebar -- this app's SQLite cache is the single
	 * source of truth for it, full stop.
	 */
	listSessions(): AgentSessionSummary[] {
		return this.runtime.sortedSessions();
	}

	async listSlashCommands(): Promise<AgentSlashCommand[]> {
		if (!this.lastActiveProjectKey) {
			return [];
		}
		const connection = this.connections.get(this.lastActiveProjectKey);
		await connection?.awaitSetup();
		return connection?.listSlashCommands() ?? [];
	}

	/**
	 * Pull-based fallback for the composer's config options (currently just
	 * the model list): the push-based "config" agentUpdate emitted by the
	 * eager home-directory/project warm-up (see the module-bottom priming
	 * call and prepareSession) can fire before the webview has mounted its
	 * message listener, silently dropping it. Called from the frontend's
	 * mount-time refreshComposerMenuData alongside slash commands/skills.
	 * Awaits the connection's in-flight setup (see
	 * ProjectAgentConnection.awaitSetup) rather than sampling
	 * configOptions immediately: against a real backend (devin/omp) the
	 * warm-up's process spawn + initialize + session/new handshake takes
	 * real wall-clock time (measured 0.6-3s+), so a bare snapshot read
	 * taken at webview-mount time reliably loses that race and leaves the
	 * model selector permanently empty -- the mock server's near-0ms
	 * response had been masking this.
	 */
	async listConfigOptions(): Promise<AgentConfigOption[]> {
		if (!this.lastActiveProjectKey) {
			return [];
		}
		const connection = this.connections.get(this.lastActiveProjectKey);
		await connection?.awaitSetup();
		return connection?.listConfigOptions() ?? [];
	}

	listSkills(): AgentSkill[] {
		return [];
	}

	async prepareSession(params: PrepareAgentSessionParams): Promise<PrepareAgentSessionResponse> {
		const cwd = resolveAgentCwd(params.cwd);
		const projectKey = this.runtime.projectKeyFor(cwd);
		this.lastActiveProjectKey = projectKey;
		// Recorded regardless of whether ACP preparation itself succeeds --
		// selection happened either way (mirrors native's
		// ContentView.selectProject calling RecentProjectStore.
		// upsertSelectedFolder independent of session-priming outcome).
		// Skipped for the folderless home-directory fallback (no real
		// project was chosen), matching native only ever recording an
		// actual folder selection.
		if (params.cwd && params.cwd.trim()) {
			upsertSelectedFolder(this.runtime.db, params.cwd);
		}
		return this.connectionFor(projectKey).prepareSession(params, cwd);
	}

	/**
	 * Durable, independently-tracked list of the 10 most-recently-opened
	 * project folders (see AGENTS.md / RecentProjectStore.swift) -- not
	 * derived from session history, so a folder opened but never chatted
	 * in still survives a relaunch.
	 */
	listRecentProjects(): RecentProjectSummary[] {
		return listRecentProjectsStore(this.runtime.db).map(({ path, displayName }) => ({ path, displayName }));
	}

	getAcpProvider(): AcpProviderId {
		return this.runtime.acpProvider;
	}

	setAcpProvider(provider: AcpProviderId): void {
		this.runtime.setAcpProvider(provider);
	}

	/**
	 * Selecting a session in the sidebar is pure local retrieval: it never
	 * talks to the agent runtime, only the durable cache already held in
	 * memory (see AGENTS.md). Still updates lastActiveProjectKey so
	 * listSlashCommands/listSkills/startNewChat target the right project
	 * until the user does something else. Priming the session with the
	 * live backend happens lazily, only once the user actually sends into
	 * it (see ProjectAgentConnection.primeSession).
	 */
	getSessionTranscript(sessionId: string): AgentUpdate[] {
		const session = this.runtime.sessions.get(sessionId);
		if (session) {
			this.lastActiveProjectKey = this.runtime.projectKeyFor(session.cwd);
		}
		return this.runtime.transcripts.get(sessionId) ?? [];
	}

	async deleteSession({ sessionId }: DeleteAgentSessionParams): Promise<DeleteAgentSessionResponse> {
		if (!sessionId) {
			return { deleted: false, reason: "No session was selected." };
		}
		const session = this.runtime.sessions.get(sessionId);
		const cwd = session?.cwd ?? homedir();
		const projectKey = this.runtime.projectKeyFor(cwd);
		const connection = this.connectionFor(projectKey);
		if (connection.isRunningSession(sessionId)) {
			return { deleted: false, reason: "Wait for the active agent turn to finish before deleting this chat." };
		}
		await connection.bestEffortDeleteSession(sessionId, cwd);
		this.runtime.deleteSessionEverywhere(sessionId);
		return { deleted: true };
	}

	async startNewChat(): Promise<boolean> {
		if (!this.lastActiveProjectKey) {
			return true;
		}
		return this.connections.get(this.lastActiveProjectKey)?.startNewChat() ?? true;
	}

	/**
	 * Tears every project connection down, closing-before-killing each in
	 * turn. Used both for the (currently unused by the renderer) whole-app
	 * reset RPC and for app-quit teardown.
	 */
	async reset(): Promise<void> {
		await Promise.all([...this.connections.values()].map((connection) => connection.reset()));
		this.connections.clear();
		this.lastActiveProjectKey = null;
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
		// Only fall back to "merge into whatever's last" when this update
		// carries no messageId of its own to check -- some backends omit it
		// on message chunks, so adjacency is the only correlation signal
		// available. A real, non-matching messageId (e.g. a distinct
		// synthesized send-time message, see startPrompt) is a positive
		// signal this is a genuinely new message, not a chunk continuation,
		// and must never be silently concatenated onto an unrelated prior
		// entry of the same role.
		const contiguousIndex = !update.messageId && lastEntry?.kind === "message" && lastEntry.role === update.role ? lastIndex : -1;
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
	if (update.kind === "thought") {
		const exactIndex = update.messageId
			? current.findIndex((entry) => entry.kind === "thought" && entry.messageId === update.messageId)
			: -1;
		const lastIndex = current.length - 1;
		const lastEntry = current[lastIndex];
		// Same messageId-presence guard as the "message" branch above: a
		// real, non-matching messageId means a genuinely new thought, never
		// a chunk continuation of an unrelated prior one.
		const contiguousIndex = !update.messageId && lastEntry?.kind === "thought" ? lastIndex : -1;
		const index = exactIndex >= 0 ? exactIndex : contiguousIndex;
		if (index < 0) {
			return [...current, update];
		}
		return current.map((entry, entryIndex) =>
			entryIndex === index && entry.kind === "thought"
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
				if (agentClient.isProjectRunning(params.cwd)) {
					return { accepted: false };
				}
				void agentClient.startPrompt({ ...params, prompt });
				return { accepted: true };
			},
			prepareAgentSession: async (params: PrepareAgentSessionParams): Promise<PrepareAgentSessionResponse> => {
				agentClient ??= new AgentAcpClient(sendAgentUpdate);
				return agentClient.prepareSession(params);
			},
			cancelAgentPrompt: (params: CancelAgentPromptParams) => {
				return agentClient?.cancelActiveTurn(params.sessionId) ?? false;
			},
			respondToAgentPermission: (params: RespondToAgentPermissionParams) => {
				return agentClient?.respondToPermission(params) ?? false;
			},
			listAgentSessions: async () => {
				agentClient ??= new AgentAcpClient(sendAgentUpdate);
				return agentClient.listSessions();
			},
			listRecentProjects: async () => {
				agentClient ??= new AgentAcpClient(sendAgentUpdate);
				return agentClient.listRecentProjects();
			},
			getAcpProvider: async () => {
				agentClient ??= new AgentAcpClient(sendAgentUpdate);
				return agentClient.getAcpProvider();
			},
			setAcpProvider: async (params: { provider: AcpProviderId }) => {
				agentClient ??= new AgentAcpClient(sendAgentUpdate);
				agentClient.setAcpProvider(normalizeAcpProvider(params.provider));
				return true;
			},
			listAgentSlashCommands: async () => {
				return agentClient?.listSlashCommands() ?? [];
			},
			listAgentConfigOptions: async () => {
				return agentClient?.listConfigOptions() ?? [];
			},
			listAgentSkills: async () => {
				return agentClient?.listSkills() ?? [];
			},
			getSessionTranscript: (params: GetSessionTranscriptParams) => {
				return agentClient?.getSessionTranscript(params.sessionId) ?? [];
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
			getProjectReviewSnapshot: (params: GetProjectReviewSnapshotParams) => {
				return getProjectReviewSnapshot(params.cwd);
			},
			getFileDiffPreview: (params: GetFileDiffPreviewParams) => {
				return getFileDiffPreview(params.cwd, params.file);
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
		// Electrobun's `accelerator` is just the bare key -- the Cmd/Ctrl
		// modifier is applied automatically per platform (unlike Electron's
		// "CmdOrCtrl+Q" format) -- and, unlike the Edit menu's roles below,
		// `role: "quit"` does not get a default key equivalent on its own,
		// so Cmd+Q silently did nothing without this.
		submenu: [{ label: "Quit", role: "quit", accelerator: "q" }],
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

const isMacOS = process.platform === "darwin";
const TRAFFIC_LIGHT_OFFSET = {
	x: 18,
	y: 22,
} as const;

mainWindow = new BrowserWindow({
	title: "Level5 Build",
	url,
	titleBarStyle: "hiddenInset",
	trafficLightOffset: TRAFFIC_LIGHT_OFFSET,
	// Required for the sidebar/floating capsules' translucent surfaces to
	// reveal genuine NSVisualEffectView vibrancy (see applyMacWindowEffects)
	// instead of flatly blurring an opaque window background.
	...(isMacOS ? { transparent: true } : {}),
	frame: {
		width: 1280,
		height: 800,
		x: 200,
		y: 200,
	},
	rpc,
});

mainWindow.setWindowButtonPosition(TRAFFIC_LIGHT_OFFSET.x, TRAFFIC_LIGHT_OFFSET.y);

if (isMacOS) {
	const { vibrancy, shadow } = applyMacWindowEffects(mainWindow);
	console.log(`macOS window effects applied (vibrancy=${vibrancy}, shadow=${shadow})`);
}

// Eagerly primes the home-directory ("no project selected") composer on
// every launch, mirroring native's AgentSessionModel.start() eagerly
// priming the home-directory key (see AGENTS.md) -- so the model
// selector/slash commands are available even before a project is chosen,
// not just after. Warm-up only: ensureSession's `persist: false` path
// means this never creates a sidebar row or SQLite write on its own; a
// New Chat still only appears once the user actually sends a first
// message (see ensureSession/persistCurrentSession).
agentClient ??= new AgentAcpClient(sendAgentUpdate);
void agentClient.prepareSession({ cwd: null, approvalMode: DEFAULT_APPROVAL_MODE });

// Close-before-kill teardown for every project's process before the app
// process actually exits, mirroring the native app's rationale
// (AgentSessionModel.closeSessionsAndTerminateClient / Level5AppDelegate):
// killing a project's process without first closing every session it
// created/primed permanently orphans those sessions server-side on real
// Devin ("already open in another process"), including from this app's own
// next relaunch. `isQuitting` guards against re-entering teardown from
// multiple signal sources racing each other.
let isQuitting = false;

async function teardownAgentClientAndExitSafely(exitCode = 0): Promise<void> {
	try {
		await teardownAgentClientAndExit(exitCode);
	} catch (error) {
		// Never let a teardown failure leave Cmd+Q/quit looking like it did
		// nothing -- always exit even if close-before-kill best-effort work
		// throws.
		console.warn("Error during quit teardown:", error);
		process.exit(exitCode);
	}
}

async function teardownAgentClientAndExit(exitCode = 0): Promise<void> {
	if (agentClient) {
		await agentClient.reset().catch(() => undefined);
		agentClient = null;
	}
	process.exit(exitCode);
}

// A graceful Cmd+Q/Dock quit fires Electrobun's "before-quit" event.
// ElectrobunEvent's response is synchronous-only (no async deferral
// mechanism like native's NSApplication .terminateLater), so the handshake
// here is: cancel the first quit request, run async teardown, then exit the
// process directly once it completes.
Electrobun.events.on("before-quit", (event: ElectrobunEvent<unknown, { allow: boolean }>) => {
	if (isQuitting) {
		return;
	}
	isQuitting = true;
	event.response = { allow: false };
	void teardownAgentClientAndExitSafely();
});

// A raw `pkill`/SIGTERM restart (e.g. during local dev iteration) bypasses
// "before-quit" entirely; without these handlers, that would orphan the
// previous run's devin acp process(es)/sessions.
for (const signal of ["SIGTERM", "SIGINT"] as const) {
	process.on(signal, () => {
		if (isQuitting) {
			return;
		}
		isQuitting = true;
		void teardownAgentClientAndExitSafely();
	});
}

process.on("exit", () => {
	// Last-resort synchronous fallback only ("exit" cannot await async
	// work); the graceful paths above (before-quit, SIGTERM/SIGINT) are
	// what normally perform the close-before-kill handshake.
	if (!isQuitting) {
		agentClient?.reset();
	}
});
