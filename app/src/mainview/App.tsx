import {
	type ButtonHTMLAttributes,
	type KeyboardEvent,
	type MouseEvent,
	type PointerEvent,
	type ReactNode,
	useEffect,
	useRef,
	useState,
} from "react";
import { useAtom } from "jotai";
import {
	Bot,
	Check,
	ChevronDown,
	Circle,
	Folder,
	GitBranch,
	Laptop,
	LoaderCircle,
	MessageSquarePlus,
	MoreHorizontal,
	PanelLeftClose,
	PanelLeftOpen,
	Plus,
	Send,
	Settings,
	ShieldCheck,
	Sparkles,
	SquareTerminal,
	Trash2,
	User,
	X,
} from "lucide-react";
import appIcon from "@/assets/app-icon.png";
import { electroview } from "@/lib/electrobun";
import { cn } from "@/lib/utils";
import { isSidebarCollapsedAtom, sidebarWidthAtom } from "@/state/ui";
import type {
	ApprovalModeId,
	MockAgentUpdate,
	MockContentBlock,
	MockMessageUpdate,
	MockModelId,
	MockPermissionRequest,
	MockPlanItem,
	MockRunStatus,
	MockSessionSummary,
	MockToolCall,
} from "@shared/rpc";

const SIDEBAR_MIN_WIDTH = 260;
const SIDEBAR_MAX_WIDTH = 420;
const SIDEBAR_COLLAPSED_WIDTH = 0;
const SIDEBAR_FLOATING_TOGGLE_GAP = 8;
const SIDEBAR_FLOATING_TOGGLE_TOP = 30;
const COMPOSER_MIN_HEIGHT = 56;
const COMPOSER_MAX_HEIGHT = 192;

type SidebarButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
	children: ReactNode;
};

type ChatMessage = {
	id: string;
	role: "user" | "agent";
	text: string;
};

type ToolCallView = MockToolCall & {
	text?: string;
};

type TranscriptItem =
	| { type: "message"; key: string; message: ChatMessage }
	| { type: "plan"; key: string; items: MockPlanItem[] }
	| { type: "tool"; key: string; tool: ToolCallView }
	| { type: "permission"; key: string; request: MockPermissionRequest }
	| { type: "error"; key: string; message: string };

type SessionContextMenu = {
	sessionId: string;
	x: number;
	y: number;
};

function SidebarButton({ children, className, ...props }: SidebarButtonProps) {
	return (
		<button
			type="button"
			className={cn(
				"electrobun-webkit-app-region-no-drag flex items-center rounded-2xl text-left transition-colors",
				"focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--app-accent)]/35",
				className,
			)}
			{...props}
		>
			{children}
		</button>
	);
}

function clampSidebarWidth(width: number) {
	return Math.min(Math.max(width, SIDEBAR_MIN_WIDTH), SIDEBAR_MAX_WIDTH);
}

function contentText(content: MockContentBlock): string {
	if (content.type === "text" && typeof content.text === "string") {
		return content.text;
	}
	return JSON.stringify(content);
}

function toolContentText(content: unknown[] | undefined): string | undefined {
	if (!content || content.length === 0) {
		return undefined;
	}
	const rendered = content
		.map((entry) => {
			if (!entry || typeof entry !== "object") {
				return "";
			}
			const object = entry as Record<string, unknown>;
			if (object.type === "content") {
				const inner = object.content as Record<string, unknown> | undefined;
				return typeof inner?.text === "string" ? inner.text : "";
			}
			if (object.type === "terminal" && typeof object.terminalId === "string") {
				return `Terminal ${object.terminalId}`;
			}
			if (object.type === "diff" && typeof object.path === "string") {
				return `Diff: ${object.path}`;
			}
			return "";
		})
		.filter(Boolean)
		.join("\n");
	return rendered || undefined;
}

function statusLabel(status: MockRunStatus, stopReason: string | null) {
	if (status === "starting") return "Starting mock agent";
	if (status === "running") return "Mock agent is working";
	if (status === "error") return "Mock agent needs attention";
	if (stopReason) return `Stopped: ${stopReason}`;
	return "Ready";
}

function statusDotClass(status: string) {
	if (status === "completed") return "text-emerald-600";
	if (status === "failed" || status === "error") return "text-red-500";
	if (status === "in_progress" || status === "running" || status === "starting") return "text-[var(--app-accent)]";
	return "text-muted-foreground";
}

function shortFolderName(path: string | null) {
	if (!path) return "Select folder";
	const parts = path.split("/").filter(Boolean);
	return parts.length > 0 ? parts[parts.length - 1] : path;
}

function sessionTitle(session: MockSessionSummary | undefined) {
	const title = session?.title.trim();
	return title || "New chat";
}

function sortSessions(sessions: MockSessionSummary[]) {
	return [...sessions].sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
}

function upsertSession(sessions: MockSessionSummary[], nextSession: MockSessionSummary) {
	const withoutCurrent = sessions.filter((session) => session.sessionId !== nextSession.sessionId);
	return sortSessions([...withoutCurrent, nextSession]);
}

function isMissingRpcHandlerError(error: unknown, methodName: string) {
	return error instanceof Error && error.message.includes("has no handler") && error.message.includes(methodName);
}

function sessionActivityLabel(status: MockRunStatus) {
	if (status === "starting" || status === "running") return "Chat is working";
	if (status === "completed") return "Chat completed";
	return undefined;
}

function SessionActivityIndicator({ status }: { status: MockRunStatus }) {
	if (status === "starting" || status === "running") {
		return (
			<span
				aria-label={sessionActivityLabel(status)}
				className="ml-auto flex size-5 shrink-0 items-center justify-center text-muted-foreground"
			>
				<LoaderCircle className="size-4 animate-spin" strokeWidth={2} />
			</span>
		);
	}
	if (status === "completed") {
		return (
			<span
				aria-label={sessionActivityLabel(status)}
				className="ml-auto flex size-5 shrink-0 items-center justify-center text-[var(--app-accent)]"
			>
				<Sparkles className="size-4" strokeWidth={2} />
			</span>
		);
	}
	return null;
}

function App() {
	const [isSidebarCollapsed, setIsSidebarCollapsed] = useAtom(isSidebarCollapsedAtom);
	const [sidebarWidth, setSidebarWidth] = useAtom(sidebarWidthAtom);
	const [prompt, setPrompt] = useState("");
	const [projectFolder, setProjectFolder] = useState<string | null>(null);
	const [model, setModel] = useState<MockModelId>("mock-pro");
	const [approvalMode, setApprovalMode] = useState<ApprovalModeId>("ask");
	const [transcriptItems, setTranscriptItems] = useState<TranscriptItem[]>([]);
	const [sessions, setSessions] = useState<MockSessionSummary[]>([]);
	const [activeSessionId, setActiveSessionId] = useState<string | null>(null);
	const [contextMenu, setContextMenu] = useState<SessionContextMenu | null>(null);
	const [deleteTargetId, setDeleteTargetId] = useState<string | null>(null);
	const [runStatus, setRunStatus] = useState<MockRunStatus>("idle");
	const [stopReason, setStopReason] = useState<string | null>(null);
	const textareaRef = useRef<HTMLTextAreaElement | null>(null);
	const transcriptEndRef = useRef<HTMLDivElement | null>(null);
	const optimisticUserTextRef = useRef<string | null>(null);
	const currentPlanKeyRef = useRef("plan-initial");
	const SidebarToggleIcon = isSidebarCollapsed ? PanelLeftOpen : PanelLeftClose;
	const renderedSidebarWidth = isSidebarCollapsed ? SIDEBAR_COLLAPSED_WIDTH : clampSidebarWidth(sidebarWidth);
	const isRunning = runStatus === "starting" || runStatus === "running";
	const hasConversation = transcriptItems.length > 0;
	const activeSessionStatus = activeSessionId ? runStatus : "idle";
	const deleteTarget = deleteTargetId ? sessions.find((session) => session.sessionId === deleteTargetId) : undefined;
	const menuSession = contextMenu ? sessions.find((session) => session.sessionId === contextMenu.sessionId) : undefined;

	useEffect(() => {
		const handler = (update: MockAgentUpdate) => {
			if (update.kind === "status") {
				setRunStatus(update.status);
				if (update.sessionId) {
					setActiveSessionId(update.sessionId);
					void refreshMockSessions();
				}
				return;
			}
			if (update.kind === "message") {
				applyMessageUpdate(update);
				return;
			}
			if (update.kind === "plan") {
				setTranscriptItems((current) => upsertPlanItem(current, update.items, currentPlanKeyRef.current));
				return;
			}
			if (update.kind === "tool") {
				setTranscriptItems((current) => upsertToolItem(current, update.tool));
				return;
			}
			if (update.kind === "permission") {
				setTranscriptItems((current) => upsertPermissionItem(current, update.request));
				return;
			}
			if (update.kind === "session") {
				setSessions((current) => upsertSession(current, update.session));
				if (update.session.sessionId) {
					setActiveSessionId(update.session.sessionId);
				}
				void refreshMockSessions();
				return;
			}
			if (update.kind === "stop") {
				setStopReason(update.stopReason);
				setRunStatus("completed");
				void refreshMockSessions();
				return;
			}
			if (update.kind === "error") {
				setTranscriptItems((current) => upsertErrorItem(current, update.message));
				setRunStatus("error");
			}
		};

		const rpc = electroview.rpc;
		rpc?.addMessageListener("mockAgentUpdate", handler);
		return () => rpc?.removeMessageListener("mockAgentUpdate", handler);
	}, []);

	useEffect(() => {
		if (!contextMenu) {
			return;
		}

		function closeMenu() {
			setContextMenu(null);
		}

		function handleKeyDown(event: globalThis.KeyboardEvent) {
			if (event.key === "Escape") {
				closeMenu();
			}
		}

		document.addEventListener("pointerdown", closeMenu);
		document.addEventListener("keydown", handleKeyDown);
		return () => {
			document.removeEventListener("pointerdown", closeMenu);
			document.removeEventListener("keydown", handleKeyDown);
		};
	}, [contextMenu]);

	useEffect(() => {
		if (contextMenu && !sessions.some((session) => session.sessionId === contextMenu.sessionId)) {
			setContextMenu(null);
		}
		if (deleteTargetId && !sessions.some((session) => session.sessionId === deleteTargetId)) {
			setDeleteTargetId(null);
		}
	}, [contextMenu, deleteTargetId, sessions]);

	useEffect(() => {
		const textarea = textareaRef.current;
		if (!textarea) {
			return;
		}
		textarea.style.height = "0px";
		textarea.style.height = `${Math.min(Math.max(textarea.scrollHeight, COMPOSER_MIN_HEIGHT), COMPOSER_MAX_HEIGHT)}px`;
		textarea.style.overflowY = textarea.scrollHeight > COMPOSER_MAX_HEIGHT ? "auto" : "hidden";
	}, [prompt]);

	useEffect(() => {
		transcriptEndRef.current?.scrollIntoView({ block: "end" });
	}, [transcriptItems]);

	function applyMessageUpdate(update: MockMessageUpdate) {
		const text = contentText(update.content);
		if (update.role === "user" && optimisticUserTextRef.current === text) {
			optimisticUserTextRef.current = null;
			return;
		}

		setTranscriptItems((current) => upsertMessageItem(current, { id: update.messageId, role: update.role, text }));
	}

	function mergeToolCall(current: ToolCallView | undefined, tool: MockToolCall): ToolCallView {
		const nextTool = {
			...tool,
			text: toolContentText(tool.content),
		};
		if (!current) {
			return nextTool;
		}
		return {
			...current,
			...nextTool,
			title: nextTool.title === "Mock tool" ? current.title : nextTool.title,
			kind: nextTool.kind === "tool" ? current.kind : nextTool.kind,
		};
	}

	function upsertMessageItem(current: TranscriptItem[], nextMessage: ChatMessage): TranscriptItem[] {
		const index = current.findIndex((item) => item.type === "message" && item.message.id === nextMessage.id);
		if (index < 0) {
			return [...current, { type: "message", key: `message-${nextMessage.id}`, message: nextMessage }];
		}
		return current.map((item, itemIndex) =>
			itemIndex === index && item.type === "message"
				? { ...item, message: { ...item.message, text: `${item.message.text}${nextMessage.text}` } }
				: item,
		);
	}

	function upsertPlanItem(current: TranscriptItem[], items: MockPlanItem[], key: string): TranscriptItem[] {
		const index = current.findIndex((item) => item.key === key);
		if (index < 0) {
			return [...current, { type: "plan", key, items }];
		}
		return current.map((item, itemIndex) => (itemIndex === index && item.type === "plan" ? { ...item, items } : item));
	}

	function upsertToolItem(current: TranscriptItem[], tool: MockToolCall): TranscriptItem[] {
		const index = current.findIndex((item) => item.type === "tool" && item.tool.toolCallId === tool.toolCallId);
		if (index < 0) {
			return [...current, { type: "tool", key: `tool-${tool.toolCallId}`, tool: mergeToolCall(undefined, tool) }];
		}
		return current.map((item, itemIndex) =>
			itemIndex === index && item.type === "tool" ? { ...item, tool: mergeToolCall(item.tool, tool) } : item,
		);
	}

	function upsertPermissionItem(current: TranscriptItem[], request: MockPermissionRequest): TranscriptItem[] {
		const key = `permission-${String(request.requestId)}`;
		const index = current.findIndex((item) => item.key === key);
		if (index < 0) {
			return [...current, { type: "permission", key, request }];
		}
		return current.map((item, itemIndex) => (itemIndex === index ? { type: "permission", key, request } : item));
	}

	function upsertErrorItem(current: TranscriptItem[], message: string): TranscriptItem[] {
		return [...current.filter((item) => item.type !== "error"), { type: "error", key: `error-${Date.now()}`, message }];
	}

	async function refreshMockSessions() {
		try {
			const nextSessions = await electroview.rpc?.request.listMockSessions();
			if (nextSessions) {
				setSessions(sortSessions(nextSessions));
			}
		} catch (error) {
			if (isMissingRpcHandlerError(error, "listMockSessions")) {
				return;
			}
			setTranscriptItems((current) =>
				upsertErrorItem(current, error instanceof Error ? error.message : "Failed to refresh chats."),
			);
		}
	}

	function resetConversationPane() {
		optimisticUserTextRef.current = null;
		setPrompt("");
		setTranscriptItems([]);
		currentPlanKeyRef.current = `plan-${Date.now()}`;
		setStopReason(null);
	}

	function handleResizePointerDown(event: PointerEvent<HTMLDivElement>) {
		if (isSidebarCollapsed) {
			return;
		}

		event.preventDefault();
		event.currentTarget.setPointerCapture(event.pointerId);
		setSidebarWidth(clampSidebarWidth(event.clientX));
	}

	function handleResizePointerMove(event: PointerEvent<HTMLDivElement>) {
		if (!event.currentTarget.hasPointerCapture(event.pointerId)) {
			return;
		}

		setSidebarWidth(clampSidebarWidth(event.clientX));
	}

	async function handleSelectFolder() {
		const folder = await electroview.rpc?.request.selectProjectFolder();
		if (folder) {
			setProjectFolder(folder);
		}
	}

	async function handleSend() {
		const trimmedPrompt = prompt.trim();
		if (!trimmedPrompt || isRunning) {
			return;
		}

		setStopReason(null);
		setPrompt("");
		setRunStatus("starting");
		optimisticUserTextRef.current = trimmedPrompt;
		currentPlanKeyRef.current = `plan-${Date.now()}`;
		setTranscriptItems((current) =>
			upsertMessageItem(current, { id: `local-${Date.now()}`, role: "user", text: trimmedPrompt }),
		);

		const response = await electroview.rpc?.request.startMockPrompt({
			prompt: trimmedPrompt,
			cwd: projectFolder,
			model,
			approvalMode,
		});
		if (!response?.accepted) {
			optimisticUserTextRef.current = null;
			setRunStatus("idle");
			setTranscriptItems((current) => upsertErrorItem(current, "The mock agent is already running or the prompt was empty."));
			return;
		}
		if (response.sessionId) {
			setActiveSessionId(response.sessionId);
			void refreshMockSessions();
		}
	}

	function handleComposerKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
		if (event.key !== "Enter" || event.shiftKey) {
			return;
		}
		event.preventDefault();
		void handleSend();
	}

	async function handlePermission(requestId: number | string, optionId: string) {
		const accepted = await electroview.rpc?.request.respondToMockPermission({ requestId, optionId });
		if (accepted) {
			const key = `permission-${String(requestId)}`;
			setTranscriptItems((current) => current.filter((item) => item.key !== key));
		}
	}

	async function handleNewChat() {
		if (isRunning) {
			return;
		}
		const started = await electroview.rpc?.request.startNewMockChat();
		if (started === false) {
			setTranscriptItems((current) => upsertErrorItem(current, "Wait for the active agent turn to finish before starting a new chat."));
			return;
		}
		resetConversationPane();
		setActiveSessionId(null);
		setContextMenu(null);
		setDeleteTargetId(null);
		setRunStatus("idle");
	}

	async function handleSelectSession(sessionId: string) {
		if (isRunning || sessionId === activeSessionId) {
			return;
		}
		resetConversationPane();
		setContextMenu(null);
		setActiveSessionId(sessionId);
		setRunStatus("idle");
		const response = await electroview.rpc?.request.loadMockSession({ sessionId });
		if (!response?.loaded) {
			setSessions((current) => current.filter((session) => session.sessionId !== sessionId));
			setActiveSessionId(null);
			setTranscriptItems((current) => upsertErrorItem(current, response?.reason ?? "Failed to load chat."));
		}
		void refreshMockSessions();
	}

	function handleSessionContextMenu(event: MouseEvent<HTMLButtonElement>, sessionId: string) {
		event.preventDefault();
		event.stopPropagation();
		setContextMenu({ sessionId, x: event.clientX, y: event.clientY });
	}

	function openDeleteDialog(sessionId: string) {
		setDeleteTargetId(sessionId);
		setContextMenu(null);
	}

	async function confirmDeleteSession() {
		if (!deleteTargetId) {
			return;
		}
		const targetId = deleteTargetId;
		const response = await electroview.rpc?.request.deleteMockSession({ sessionId: targetId });
		if (!response?.deleted) {
			setDeleteTargetId(null);
			setTranscriptItems((current) => upsertErrorItem(current, response?.reason ?? "Failed to delete chat."));
			return;
		}

		setSessions((current) => current.filter((session) => session.sessionId !== targetId));
		setDeleteTargetId(null);
		setContextMenu(null);
		if (targetId === activeSessionId) {
			resetConversationPane();
			setActiveSessionId(null);
			setRunStatus("idle");
		}
	}

	return (
		<div
			className="app-gradient-background electrobun-webkit-app-region-drag fixed inset-0 flex h-screen w-screen overflow-hidden text-foreground"
			onDoubleClick={() => electroview.rpc?.request.toggleMaximizeWindow()}
		>
			<aside
				className={cn(
					"relative flex h-full shrink-0 flex-col overflow-hidden bg-[var(--app-sidebar-surface)] backdrop-blur-2xl transition-[width] duration-200 ease-out",
					isSidebarCollapsed
						? "min-w-0 max-w-0 border-r-0 shadow-none"
						: "min-w-[260px] max-w-[420px] border-r border-[var(--app-sidebar-border)] shadow-[0_18px_60px_rgba(17,24,39,0.08)]",
				)}
				style={{ width: `${renderedSidebarWidth}px` }}
				aria-label="Project sidebar"
				onDoubleClick={(event) => event.stopPropagation()}
			>
				{isSidebarCollapsed ? null : (
					<>
						<div className="h-12 shrink-0" />

						<div className="flex min-h-0 flex-1 flex-col px-3 pb-4 pt-0">
							<SidebarButton
								aria-label="New chat"
								title="New chat"
								disabled={isRunning}
								className="h-11 w-full justify-start gap-3 px-3 text-[14px] font-medium text-foreground hover:bg-white/70 disabled:cursor-not-allowed disabled:opacity-45"
								onClick={() => void handleNewChat()}
							>
								<MessageSquarePlus className="size-4 shrink-0" strokeWidth={1.8} />
								<span className="truncate">New chat</span>
							</SidebarButton>

							<section className="mt-3 flex min-h-0 flex-1 flex-col" aria-label="All chats">
								<div className="flex h-9 shrink-0 items-center justify-between px-3 text-[13px] font-semibold text-muted-foreground">
									<span>All chats</span>
									<MoreHorizontal className="size-4" strokeWidth={1.8} />
								</div>
								{sessions.length === 0 ? (
									<div className="flex flex-1 items-start justify-center px-3 pt-3 text-center text-[14px] font-semibold text-muted-foreground">
										No recent chats
									</div>
								) : (
									<div className="min-h-0 flex-1 overflow-y-auto pr-1">
										<div className="flex flex-col gap-1">
											{sessions.map((session) => {
												const isActive = session.sessionId === activeSessionId;
												return (
													<SidebarButton
														key={session.sessionId}
														aria-label={`Open ${sessionTitle(session)}`}
														title={sessionTitle(session)}
														aria-disabled={isRunning}
														className={cn(
															"h-10 w-full justify-start gap-2 px-3 text-[14px] font-medium",
															isActive
																? "bg-[var(--app-selected-surface)] text-foreground"
																: "text-muted-foreground hover:bg-white/70 hover:text-foreground",
															isRunning ? "cursor-not-allowed opacity-60" : "",
														)}
														onClick={() => void handleSelectSession(session.sessionId)}
														onContextMenu={(event) => handleSessionContextMenu(event, session.sessionId)}
													>
														<MessageSquarePlus className="size-4 shrink-0" strokeWidth={1.7} />
														<span className="min-w-0 flex-1 truncate">{sessionTitle(session)}</span>
														{isActive ? <SessionActivityIndicator status={activeSessionStatus} /> : null}
													</SidebarButton>
												);
											})}
										</div>
									</div>
								)}
							</section>

							<div className="border-t border-[var(--app-sidebar-border)] pt-3">
								<SidebarButton
									aria-label="Settings"
									title="Settings"
									className="h-11 w-full justify-start gap-3 px-3 text-[14px] font-medium text-muted-foreground hover:bg-white/70 hover:text-foreground"
								>
									<Settings className="size-4 shrink-0" strokeWidth={1.8} />
									<span className="truncate">Settings</span>
								</SidebarButton>
							</div>
						</div>

						<div
							role="separator"
							aria-orientation="vertical"
							aria-label="Resize sidebar"
							className="electrobun-webkit-app-region-no-drag absolute inset-y-0 right-[-4px] w-2 cursor-col-resize"
							onPointerDown={handleResizePointerDown}
							onPointerMove={handleResizePointerMove}
						>
							<div className="mx-auto h-full w-px bg-transparent transition-colors hover:bg-[var(--app-sidebar-border)]" />
						</div>
					</>
				)}
			</aside>

			{contextMenu && menuSession ? (
				<div
					className="electrobun-webkit-app-region-no-drag fixed z-30 w-44 rounded-[20px] border border-[var(--app-sidebar-border)] bg-white/92 p-1.5 shadow-[0_18px_46px_rgba(17,24,39,0.18)] backdrop-blur-2xl"
					style={{ left: contextMenu.x, top: contextMenu.y }}
					onDoubleClick={(event) => event.stopPropagation()}
					onPointerDown={(event) => event.stopPropagation()}
				>
					<button
						type="button"
						className="flex h-10 w-full items-center gap-2 rounded-2xl px-3 text-left text-[14px] font-semibold text-red-600 transition-colors hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-45"
						disabled={isRunning && contextMenu.sessionId === activeSessionId}
						onClick={() => openDeleteDialog(contextMenu.sessionId)}
					>
						<Trash2 className="size-4 shrink-0" strokeWidth={1.9} />
						<span>Delete</span>
					</button>
				</div>
			) : null}

			<div
				className="electrobun-webkit-app-region-no-drag fixed z-10 inline-flex h-11 w-auto items-center gap-2 rounded-full border border-[var(--app-sidebar-border)] bg-white/80 py-1 pr-4 pl-1.5 text-muted-foreground shadow-[0_8px_24px_rgba(17,24,39,0.12)] backdrop-blur-2xl"
				style={{
					left: `${renderedSidebarWidth + SIDEBAR_FLOATING_TOGGLE_GAP}px`,
					top: `${SIDEBAR_FLOATING_TOGGLE_TOP}px`,
				}}
				onDoubleClick={(event) => event.stopPropagation()}
			>
				<SidebarButton
					aria-label={isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
					title={isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
					className="size-9 justify-center rounded-full hover:bg-accent hover:text-foreground"
					onClick={() => setIsSidebarCollapsed((value) => !value)}
				>
					<SidebarToggleIcon className="size-5 shrink-0" strokeWidth={1.8} />
				</SidebarButton>
				<img src={appIcon} alt="" className="size-6 shrink-0 rounded-full" />
				<span className="shrink-0 text-[14px] font-semibold text-foreground">Level5</span>
			</div>

			<main className="electrobun-webkit-app-region-no-drag flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden px-6 pb-6 pt-20" aria-label="Workspace">
				<div className={cn("mx-auto flex min-h-0 w-full max-w-5xl flex-1 flex-col", hasConversation ? "" : "justify-center")}>
					<div className={cn("flex min-h-0 w-full flex-col", hasConversation ? "relative h-full" : "")}>
						{hasConversation ? (
							<div
								className="app-scrollbar-transparent fixed bottom-0 right-0 top-0 overflow-y-auto overscroll-contain px-6 pb-56 pt-24"
								style={{ left: `${renderedSidebarWidth}px` }}
							>
								<div className="mx-auto flex w-full max-w-3xl flex-col gap-4">
									{transcriptItems.map((item) => {
										if (item.type === "message") {
											return <MessageBubble key={item.key} message={item.message} />;
										}
										if (item.type === "plan") {
											return <PlanCard key={item.key} items={item.items} />;
										}
										if (item.type === "tool") {
											return <ToolCallCard key={item.key} tool={item.tool} />;
										}
										if (item.type === "permission") {
											return <PermissionCard key={item.key} request={item.request} onRespond={handlePermission} />;
										}
										return <ErrorCard key={item.key} message={item.message} />;
									})}
									<div ref={transcriptEndRef} />
								</div>
							</div>
						) : null}

						<div className={cn("mx-auto w-full max-w-3xl shrink-0 overflow-hidden rounded-[24px] border border-[rgba(0,0,0,0.1)] bg-[rgba(255,255,255,0.72)] shadow-[0_24px_70px_rgba(17,24,39,0.13)] backdrop-blur-2xl", hasConversation ? "relative z-10 mt-auto" : "")}>
							<div className="px-6 pt-4">
								<textarea
									ref={textareaRef}
									value={prompt}
									placeholder="Do anything"
									aria-label="Message the mock agent"
									className="block w-full resize-none bg-transparent text-[22px] font-medium leading-6 text-foreground placeholder:text-muted-foreground/70 focus:outline-none"
									style={{ minHeight: COMPOSER_MIN_HEIGHT, maxHeight: COMPOSER_MAX_HEIGHT }}
									onChange={(event) => setPrompt(event.target.value)}
									onKeyDown={handleComposerKeyDown}
									disabled={isRunning}
								/>
							</div>

							<div className="flex items-center gap-3 px-5 pb-3 pt-1">
								<IconButton label="Add attachment">
									<Plus className="size-5" strokeWidth={1.9} />
								</IconButton>
								<SelectControl
									icon={<ShieldCheck className="size-4 text-[var(--app-accent)]" strokeWidth={1.8} />}
									label="Approval mode"
									value={approvalMode}
									onChange={(value) => setApprovalMode(value as ApprovalModeId)}
									options={[
										{ value: "ask", label: "Approve for me" },
										{ value: "architect", label: "Architect" },
										{ value: "code", label: "Code" },
										{ value: "auto", label: "Auto" },
									]}
								/>

								<div className="min-w-0 flex-1" />

								<SelectControl
									label="Model"
									value={model}
									onChange={(value) => setModel(value as MockModelId)}
									options={[
										{ value: "mock-fast", label: "Mock Fast" },
										{ value: "mock-pro", label: "Mock Pro" },
										{ value: "mock-deep", label: "Mock Deep" },
									]}
								/>
								<button
									type="button"
									aria-label="Send message"
									className={cn(
										"flex size-11 shrink-0 items-center justify-center rounded-full transition-colors",
										prompt.trim() && !isRunning
											? "bg-foreground text-background shadow-[0_10px_24px_rgba(17,24,39,0.2)] hover:bg-foreground/90"
											: "bg-muted text-muted-foreground",
									)}
									disabled={!prompt.trim() || isRunning}
									onClick={() => void handleSend()}
								>
									<Send className="size-5" strokeWidth={2} />
								</button>
							</div>

							<footer className="flex h-12 items-center justify-between bg-white/25 px-6 text-[14px] font-medium text-muted-foreground">
								<div className="flex min-w-0 items-center gap-4">
									<button
										type="button"
										className="flex min-w-0 items-center gap-2 rounded-2xl px-2 py-2 text-foreground transition-colors hover:bg-white/60"
										onClick={() => void handleSelectFolder()}
										title={projectFolder ?? "Select folder"}
									>
										<Folder className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
										<span className="truncate">{shortFolderName(projectFolder)}</span>
									</button>
									<div className="hidden items-center gap-2 md:flex">
										<Laptop className="size-4" strokeWidth={1.8} />
										<span>Work locally</span>
										<ChevronDown className="size-4" strokeWidth={1.8} />
									</div>
									<div className="hidden items-center gap-2 md:flex">
										<GitBranch className="size-4" strokeWidth={1.8} />
										<span>main</span>
										<ChevronDown className="size-4" strokeWidth={1.8} />
									</div>
								</div>
								<div className="flex shrink-0 items-center gap-2 text-[12px]">
									<Circle className={cn("size-2 fill-current", statusDotClass(runStatus))} strokeWidth={0} />
									<span>{statusLabel(runStatus, stopReason)}</span>
								</div>
							</footer>
						</div>
					</div>
				</div>
			</main>

			{deleteTarget ? (
				<div
					className="electrobun-webkit-app-region-no-drag fixed inset-0 z-40 flex items-center justify-center bg-foreground/18 p-6 backdrop-blur-md"
					role="presentation"
					onDoubleClick={(event) => event.stopPropagation()}
					onMouseDown={(event) => {
						if (event.target === event.currentTarget) {
							setDeleteTargetId(null);
						}
					}}
				>
					<section
						role="dialog"
						aria-modal="true"
						aria-labelledby="delete-chat-title"
						aria-describedby="delete-chat-description"
						className="w-full max-w-sm rounded-[24px] border border-[var(--app-sidebar-border)] bg-white/92 p-5 shadow-[0_28px_80px_rgba(17,24,39,0.22)] backdrop-blur-2xl"
					>
						<div className="flex items-start gap-3">
							<div className="flex size-10 shrink-0 items-center justify-center rounded-full bg-red-50 text-red-600">
								<Trash2 className="size-5" strokeWidth={1.9} />
							</div>
							<div className="min-w-0 flex-1">
								<h2 id="delete-chat-title" className="text-[18px] font-semibold text-foreground">
									Delete chat?
								</h2>
								<p id="delete-chat-description" className="mt-1 text-[14px] leading-5 text-muted-foreground">
									This will remove "{sessionTitle(deleteTarget)}" from your recent chats.
								</p>
							</div>
						</div>
						<div className="mt-6 flex justify-end gap-2">
							<button
								type="button"
								className="h-10 rounded-2xl px-4 text-[14px] font-semibold text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
								onClick={() => setDeleteTargetId(null)}
							>
								Cancel
							</button>
							<button
								type="button"
								className="h-10 rounded-2xl bg-red-600 px-4 text-[14px] font-semibold text-white shadow-[0_10px_24px_rgba(220,38,38,0.2)] transition-colors hover:bg-red-700 disabled:cursor-not-allowed disabled:opacity-45"
								disabled={isRunning && deleteTarget.sessionId === activeSessionId}
								onClick={() => void confirmDeleteSession()}
							>
								Delete
							</button>
						</div>
					</section>
				</div>
			) : null}
		</div>
	);
}

function IconButton({ children, label, disabled = false }: { children: ReactNode; label: string; disabled?: boolean }) {
	return (
		<button
			type="button"
			aria-label={label}
			title={label}
			disabled={disabled}
			className="flex size-10 shrink-0 items-center justify-center rounded-2xl text-muted-foreground transition-colors hover:bg-white/65 hover:text-foreground disabled:cursor-not-allowed disabled:opacity-45"
		>
			{children}
		</button>
	);
}

function SelectControl({
	icon,
	label,
	value,
	options,
	onChange,
}: {
	icon?: ReactNode;
	label: string;
	value: string;
	options: Array<{ value: string; label: string }>;
	onChange: (value: string) => void;
}) {
	return (
		<label className="relative inline-flex shrink-0 items-center gap-2 rounded-2xl px-2 py-2 text-[14px] font-semibold text-foreground transition-colors hover:bg-white/65">
			{icon}
			<span className="pointer-events-none">
				{options.find((option) => option.value === value)?.label ?? value}
			</span>
			<ChevronDown className="pointer-events-none size-4 text-muted-foreground" strokeWidth={1.8} />
			<select
				aria-label={label}
				value={value}
				className="absolute inset-0 cursor-pointer opacity-0"
				onChange={(event) => onChange(event.target.value)}
			>
				{options.map((option) => (
					<option key={option.value} value={option.value}>
						{option.label}
					</option>
				))}
			</select>
		</label>
	);
}

function MessageBubble({ message }: { message: ChatMessage }) {
	const isUser = message.role === "user";
	const Icon = isUser ? User : Bot;
	return (
		<div className={cn("flex w-full gap-3", isUser ? "justify-end" : "justify-start")}>
			{isUser ? null : (
				<div className="mt-1 flex size-8 shrink-0 items-center justify-center rounded-full bg-white/75 text-[var(--app-accent)] shadow-sm">
					<Icon className="size-4" strokeWidth={1.9} />
				</div>
			)}
			<div
				className={cn(
					"max-w-3xl whitespace-pre-wrap rounded-[20px] px-4 py-3 text-[14px] leading-6 shadow-[0_12px_32px_rgba(17,24,39,0.08)]",
					isUser ? "bg-[var(--app-selected-surface)] text-foreground" : "bg-white/78 text-foreground",
				)}
			>
				{message.text}
			</div>
		</div>
	);
}

function PlanCard({ items }: { items: MockPlanItem[] }) {
	return (
		<section className="w-full max-w-3xl rounded-[20px] border border-[rgba(0,0,0,0.08)] bg-white/72 p-4 shadow-[0_12px_32px_rgba(17,24,39,0.08)]">
			<div className="mb-3 flex items-center gap-2 text-[14px] font-semibold">
				<Check className="size-4 text-[var(--app-accent)]" strokeWidth={1.9} />
				<span>Plan</span>
			</div>
			<div className="flex flex-col gap-2">
				{items.map((item, index) => (
					<div key={`${item.title}-${index}`} className="flex items-center gap-3 text-[14px]">
						<Circle className={cn("size-2 fill-current", statusDotClass(item.status ?? ""))} strokeWidth={0} />
						<span className="min-w-0 flex-1 truncate">{item.title}</span>
						{item.status ? <span className="shrink-0 text-[12px] font-medium text-muted-foreground">{item.status}</span> : null}
					</div>
				))}
			</div>
		</section>
	);
}

function ToolCallCard({ tool }: { tool: ToolCallView }) {
	return (
		<section className="w-full max-w-3xl rounded-[20px] border border-[rgba(0,0,0,0.08)] bg-white/68 p-4 shadow-[0_12px_32px_rgba(17,24,39,0.07)]">
			<div className="flex items-center gap-3">
				<SquareTerminal className="size-4 text-muted-foreground" strokeWidth={1.8} />
				<div className="min-w-0 flex-1">
					<div className="truncate text-[14px] font-semibold">{tool.title}</div>
					<div className="text-[12px] font-medium text-muted-foreground">{tool.kind}</div>
				</div>
				<span className={cn("text-[12px] font-semibold", statusDotClass(tool.status))}>{tool.status}</span>
			</div>
			{tool.text ? <pre className="mt-3 overflow-x-auto whitespace-pre-wrap rounded-2xl bg-muted/70 p-3 font-mono text-[12px] leading-5 text-muted-foreground">{tool.text}</pre> : null}
		</section>
	);
}

function PermissionCard({
	request,
	onRespond,
}: {
	request: MockPermissionRequest;
	onRespond: (requestId: number | string, optionId: string) => Promise<void>;
}) {
	return (
		<section className="w-full max-w-3xl rounded-[20px] border border-[rgba(79,109,255,0.24)] bg-white/78 p-4 shadow-[0_16px_36px_rgba(79,109,255,0.12)]">
			<div className="flex items-start gap-3">
				<ShieldCheck className="mt-0.5 size-5 text-[var(--app-accent)]" strokeWidth={1.9} />
				<div className="min-w-0 flex-1">
					<div className="text-[14px] font-semibold">{request.toolCall?.title ?? "Permission requested"}</div>
					<div className="mt-1 text-[13px] leading-5 text-muted-foreground">The mock server is waiting for a permission response.</div>
				</div>
			</div>
			<div className="mt-4 flex flex-wrap gap-2">
				{request.options.map((option) => (
					<button
						key={option.optionId}
						type="button"
						className="rounded-2xl bg-foreground px-3 py-2 text-[13px] font-semibold text-background transition-colors hover:bg-foreground/90"
						onClick={() => void onRespond(request.requestId, option.optionId)}
					>
						{option.name}
					</button>
				))}
			</div>
		</section>
	);
}

function ErrorCard({ message }: { message: string }) {
	return (
		<div className="flex w-full max-w-3xl items-center gap-3 rounded-[20px] border border-red-500/20 bg-red-50/80 p-4 text-[14px] font-medium text-red-700 shadow-[0_12px_32px_rgba(127,29,29,0.08)]">
			<X className="size-4 shrink-0" strokeWidth={2} />
			<span>{message}</span>
		</div>
	);
}

export default App;
