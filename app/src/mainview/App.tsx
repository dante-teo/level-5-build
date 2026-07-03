import {
	type ButtonHTMLAttributes,
	type KeyboardEvent,
	type MouseEvent,
	type PointerEvent,
	type ReactNode,
	type UIEvent,
	useEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { useAtom } from "jotai";
import { useStickToBottom } from "use-stick-to-bottom";
import {
	Bot,
	Check,
	ChevronDown,
	Circle,
	Folder,
	Hand,
	ListTodo,
	LoaderCircle,
	type LucideIcon,
	MessageSquarePlus,
	MoreHorizontal,
	Paperclip,
	PanelLeftClose,
	PanelLeftOpen,
	Pencil,
	Plus,
	Search,
	Send,
	Settings,
	ShieldAlert,
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
import {
	APPROVAL_MODE_LABELS,
	type ApprovalModeId,
	type MockAgentUpdate,
	type MockContentBlock,
	type MockMessageUpdate,
	type MockModelId,
	type MockPermissionRequest,
	type MockPlanItem,
	type MockPromptAttachment,
	type MockPromptAttachmentType,
	type MockRunStatus,
	type MockSessionSummary,
	type MockSkill,
	type MockSlashCommand,
	type MockToolCall,
} from "@shared/rpc";

const SIDEBAR_MIN_WIDTH = 260;
const SIDEBAR_MAX_WIDTH = 420;
const SIDEBAR_COLLAPSED_WIDTH = 0;
const SIDEBAR_FLOATING_TOGGLE_GAP = 8;
const SIDEBAR_FLOATING_TOGGLE_TOP = 30;
const COMPOSER_MIN_HEIGHT = 56;
const COMPOSER_MAX_HEIGHT = 192;

type ApprovalModeOption = {
	value: ApprovalModeId;
	label: string;
	description: string;
	icon: LucideIcon;
};

const APPROVAL_MODE_OPTIONS: ApprovalModeOption[] = [
	{
		value: "ask",
		label: APPROVAL_MODE_LABELS.ask,
		description: "Always ask before applying simulated edits or running mock tools.",
		icon: Hand,
	},
	{
		value: "auto",
		label: APPROVAL_MODE_LABELS.auto,
		description: "Only ask for actions detected as potentially unsafe.",
		icon: ShieldCheck,
	},
	{
		value: "full-access",
		label: APPROVAL_MODE_LABELS["full-access"],
		description: "Unrestricted access to any simulated file or mock tool.",
		icon: ShieldAlert,
	},
];

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
	| { type: "error"; key: string; message: string }
	| { type: "info"; key: string; message: string };

type SessionContextMenu = {
	sessionId: string;
	x: number;
	y: number;
};

type RecentProject = {
	path: string;
	name: string;
};

type AttachmentItem = MockPromptAttachment & { id: string };

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

function folderDisplayName(path: string) {
	const parts = path.split("/").filter(Boolean);
	return parts.length > 0 ? parts[parts.length - 1] : path;
}

function projectLabel(path: string | null) {
	return path ? folderDisplayName(path) : "Choose project";
}

function compactTitle(text: string) {
	const normalized = text.trim().replace(/\s+/g, " ");
	if (normalized.length <= 48) {
		return normalized;
	}
	return `${normalized.slice(0, 47).trim()}...`;
}

function isFolderlessProjectPath(path: string) {
	const normalized = path.trim();
	return normalized === "~" || normalized === "~/";
}

const SLASH_TOKEN_PATTERN = /^\/[a-zA-Z0-9_-]+$/;

function renderComposerPreview(text: string): ReactNode {
	if (!text) {
		return null;
	}
	return text.split(/(\s+)/).map((part, index) =>
		SLASH_TOKEN_PATTERN.test(part) ? (
			<span key={index} className="font-semibold text-[var(--app-accent)]">
				{part}
			</span>
		) : (
			<span key={index}>{part}</span>
		),
	);
}

function sessionProjectFolder(session: MockSessionSummary | undefined) {
	if (!session || session.isNoProject || isFolderlessProjectPath(session.cwd)) {
		return null;
	}
	return session.cwd.trim() || null;
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
	const [isProjectMenuOpen, setIsProjectMenuOpen] = useState(false);
	const [projectSearch, setProjectSearch] = useState("");
	const [model, setModel] = useState<MockModelId>("mock-pro");
	const [approvalMode, setApprovalMode] = useState<ApprovalModeId>("ask");
	const [transcriptItems, setTranscriptItems] = useState<TranscriptItem[]>([]);
	const [sessions, setSessions] = useState<MockSessionSummary[]>([]);
	const [activeSessionId, setActiveSessionId] = useState<string | null>(null);
	const [contextMenu, setContextMenu] = useState<SessionContextMenu | null>(null);
	const [deleteTargetId, setDeleteTargetId] = useState<string | null>(null);
	const [runStatus, setRunStatus] = useState<MockRunStatus>("idle");
	const [stopReason, setStopReason] = useState<string | null>(null);
	const [pendingPermission, setPendingPermission] = useState<MockPermissionRequest | null>(null);
	const [isPlusMenuOpen, setIsPlusMenuOpen] = useState(false);
	const [isApprovalMenuOpen, setIsApprovalMenuOpen] = useState(false);
	const [slashCommands, setSlashCommands] = useState<MockSlashCommand[]>([]);
	const [skills, setSkills] = useState<MockSkill[]>([]);
	const [attachments, setAttachments] = useState<AttachmentItem[]>([]);
	const [composerHeight, setComposerHeight] = useState(224);
	const textareaRef = useRef<HTMLTextAreaElement | null>(null);
	const promptOverlayRef = useRef<HTMLDivElement | null>(null);
	const composerContainerRef = useRef<HTMLDivElement | null>(null);
	const { scrollRef: transcriptScrollRef, contentRef: transcriptContentRef, scrollToBottom } = useStickToBottom();
	const projectMenuRef = useRef<HTMLDivElement | null>(null);
	const projectSearchRef = useRef<HTMLInputElement | null>(null);
	const plusMenuRef = useRef<HTMLDivElement | null>(null);
	const approvalMenuRef = useRef<HTMLDivElement | null>(null);
	const optimisticUserTextRef = useRef<string | null>(null);
	const pendingPromptProjectFolderRef = useRef<string | null | undefined>(undefined);
	const sessionProjectFoldersRef = useRef(new Map<string, string | null>());
	const currentPlanKeyRef = useRef("plan-initial");
	const SidebarToggleIcon = isSidebarCollapsed ? PanelLeftOpen : PanelLeftClose;
	const renderedSidebarWidth = isSidebarCollapsed ? SIDEBAR_COLLAPSED_WIDTH : clampSidebarWidth(sidebarWidth);
	const currentApprovalOption =
		APPROVAL_MODE_OPTIONS.find((option) => option.value === approvalMode) ?? APPROVAL_MODE_OPTIONS[0];
	const isRunning = runStatus === "starting" || runStatus === "running";
	const hasConversation = transcriptItems.length > 0;
	const activeSessionStatus = activeSessionId ? runStatus : "idle";
	const activeSession = activeSessionId ? sessions.find((session) => session.sessionId === activeSessionId) : undefined;
	const deleteTarget = deleteTargetId ? sessions.find((session) => session.sessionId === deleteTargetId) : undefined;
	const menuSession = contextMenu ? sessions.find((session) => session.sessionId === contextMenu.sessionId) : undefined;
	const firstUserMessage = transcriptItems.find(
		(item): item is Extract<TranscriptItem, { type: "message" }> =>
			item.type === "message" && item.message.role === "user",
	);
	const activeSessionTitle = sessionTitle(activeSession);
	const shouldShowSessionContext = hasConversation && Boolean(projectFolder);
	const topBarTitle =
		shouldShowSessionContext && activeSessionTitle === "New chat" && firstUserMessage
			? compactTitle(firstUserMessage.message.text)
			: shouldShowSessionContext
				? activeSessionTitle
				: "Level5";
	const topBarSubtitle = projectFolder ? folderDisplayName(projectFolder) : null;
	const recentProjects = useMemo<RecentProject[]>(() => {
		const seen = new Set<string>();
		const projects: RecentProject[] = [];

		for (const session of sortSessions(sessions)) {
			const path = sessionProjectFolder(session);
			if (!path || seen.has(path)) {
				continue;
			}
			seen.add(path);
			projects.push({ path, name: folderDisplayName(path) });
		}

		if (projectFolder && !seen.has(projectFolder)) {
			projects.unshift({ path: projectFolder, name: folderDisplayName(projectFolder) });
		}

		return projects;
	}, [projectFolder, sessions]);
	const filteredProjects = useMemo(() => {
		const search = projectSearch.trim().toLowerCase();
		if (!search) {
			return recentProjects;
		}
		return recentProjects.filter(
			(project) => project.name.toLowerCase().includes(search) || project.path.toLowerCase().includes(search),
		);
	}, [projectSearch, recentProjects]);

	useEffect(() => {
		const handler = (update: MockAgentUpdate) => {
			if (update.kind === "status") {
				setRunStatus(update.status);
				if (update.sessionId) {
					setActiveSessionId(update.sessionId);
					if (pendingPromptProjectFolderRef.current !== undefined) {
						sessionProjectFoldersRef.current.set(update.sessionId, pendingPromptProjectFolderRef.current);
					}
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
				setPendingPermission(update.request);
				return;
			}
			if (update.kind === "session") {
				setSessions((current) => upsertSession(current, update.session));
				if (update.session.sessionId) {
					setActiveSessionId(update.session.sessionId);
					if (pendingPromptProjectFolderRef.current !== undefined) {
						sessionProjectFoldersRef.current.set(update.session.sessionId, pendingPromptProjectFolderRef.current);
					}
				}
				void refreshMockSessions();
				return;
			}
			if (update.kind === "stop") {
				pendingPromptProjectFolderRef.current = undefined;
				setStopReason(update.stopReason);
				setRunStatus("completed");
				void refreshMockSessions();
				return;
			}
			if (update.kind === "error") {
				pendingPromptProjectFolderRef.current = undefined;
				setTranscriptItems((current) => upsertErrorItem(current, update.message));
				setRunStatus("error");
				return;
			}
			if (update.kind === "info") {
				setTranscriptItems((current) => appendInfoItem(current, update.id, update.message));
			}
		};

		const rpc = electroview.rpc;
		rpc?.addMessageListener("mockAgentUpdate", handler);
		return () => rpc?.removeMessageListener("mockAgentUpdate", handler);
	}, []);

	useEffect(() => {
		void refreshMockSessions({ reportErrors: false });
		void refreshComposerMenuData();
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
		if (!isProjectMenuOpen) {
			return;
		}

		function closeMenu() {
			setIsProjectMenuOpen(false);
			setProjectSearch("");
		}

		function handlePointerDown(event: globalThis.PointerEvent) {
			if (projectMenuRef.current?.contains(event.target as Node)) {
				return;
			}
			closeMenu();
		}

		function handleKeyDown(event: globalThis.KeyboardEvent) {
			if (event.key === "Escape") {
				closeMenu();
			}
		}

		document.addEventListener("pointerdown", handlePointerDown);
		document.addEventListener("keydown", handleKeyDown);
		projectSearchRef.current?.focus();
		return () => {
			document.removeEventListener("pointerdown", handlePointerDown);
			document.removeEventListener("keydown", handleKeyDown);
		};
	}, [isProjectMenuOpen]);

	useEffect(() => {
		if ((isRunning || hasConversation) && isProjectMenuOpen) {
			closeProjectMenu();
		}
	}, [hasConversation, isRunning, isProjectMenuOpen]);

	useEffect(() => {
		if (!isPlusMenuOpen) {
			return;
		}

		function closeMenu() {
			setIsPlusMenuOpen(false);
		}

		function handlePointerDown(event: globalThis.PointerEvent) {
			if (plusMenuRef.current?.contains(event.target as Node)) {
				return;
			}
			closeMenu();
		}

		function handleKeyDown(event: globalThis.KeyboardEvent) {
			if (event.key === "Escape") {
				closeMenu();
			}
		}

		document.addEventListener("pointerdown", handlePointerDown);
		document.addEventListener("keydown", handleKeyDown);
		return () => {
			document.removeEventListener("pointerdown", handlePointerDown);
			document.removeEventListener("keydown", handleKeyDown);
		};
	}, [isPlusMenuOpen]);

	useEffect(() => {
		if (isRunning && isPlusMenuOpen) {
			setIsPlusMenuOpen(false);
		}
	}, [isRunning, isPlusMenuOpen]);

	useEffect(() => {
		if (!isApprovalMenuOpen) {
			return;
		}

		function closeMenu() {
			setIsApprovalMenuOpen(false);
		}

		function handlePointerDown(event: globalThis.PointerEvent) {
			if (approvalMenuRef.current?.contains(event.target as Node)) {
				return;
			}
			closeMenu();
		}

		function handleKeyDown(event: globalThis.KeyboardEvent) {
			if (event.key === "Escape") {
				closeMenu();
			}
		}

		document.addEventListener("pointerdown", handlePointerDown);
		document.addEventListener("keydown", handleKeyDown);
		return () => {
			document.removeEventListener("pointerdown", handlePointerDown);
			document.removeEventListener("keydown", handleKeyDown);
		};
	}, [isApprovalMenuOpen]);

	useEffect(() => {
		if (isRunning && isApprovalMenuOpen) {
			setIsApprovalMenuOpen(false);
		}
	}, [isRunning, isApprovalMenuOpen]);

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
		const node = composerContainerRef.current;
		if (!node) {
			return;
		}
		const observer = new ResizeObserver((entries) => {
			const entry = entries[0];
			if (entry) {
				setComposerHeight(Math.ceil(entry.contentRect.height));
			}
		});
		observer.observe(node);
		return () => observer.disconnect();
	}, []);

	useEffect(() => {
		if (!pendingPermission) {
			textareaRef.current?.focus();
		}
	}, [pendingPermission]);

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

	function upsertErrorItem(current: TranscriptItem[], message: string): TranscriptItem[] {
		return [...current.filter((item) => item.type !== "error"), { type: "error", key: `error-${Date.now()}`, message }];
	}

	function appendInfoItem(current: TranscriptItem[], id: string, message: string): TranscriptItem[] {
		const key = `info-${id}`;
		if (current.some((item) => item.key === key)) {
			return current;
		}
		return [...current, { type: "info", key, message }];
	}

	async function refreshMockSessions({ reportErrors = true }: { reportErrors?: boolean } = {}) {
		try {
			const nextSessions = await electroview.rpc?.request.listMockSessions();
			if (nextSessions) {
				setSessions(sortSessions(nextSessions));
			}
		} catch (error) {
			if (isMissingRpcHandlerError(error, "listMockSessions")) {
				return;
			}
			if (!reportErrors) {
				return;
			}
			setTranscriptItems((current) =>
				upsertErrorItem(current, error instanceof Error ? error.message : "Failed to refresh chats."),
			);
		}
	}

	async function refreshComposerMenuData() {
		try {
			const [nextSlashCommands, nextSkills] = await Promise.all([
				electroview.rpc?.request.listMockSlashCommands() ?? Promise.resolve(undefined),
				electroview.rpc?.request.listMockSkills() ?? Promise.resolve(undefined),
			]);
			if (nextSlashCommands) {
				setSlashCommands(nextSlashCommands);
			}
			if (nextSkills) {
				setSkills(nextSkills);
			}
		} catch (error) {
			if (isMissingRpcHandlerError(error, "listMockSlashCommands") || isMissingRpcHandlerError(error, "listMockSkills")) {
				return;
			}
			// Non-fatal: the plus menu simply shows empty slash command/skill groups.
		}
	}

	function resetConversationPane() {
		optimisticUserTextRef.current = null;
		setPrompt("");
		setTranscriptItems([]);
		setAttachments([]);
		currentPlanKeyRef.current = `plan-${Date.now()}`;
		setStopReason(null);
		setPendingPermission(null);
	}

	function closeProjectMenu() {
		setIsProjectMenuOpen(false);
		setProjectSearch("");
	}

	function closePlusMenu() {
		setIsPlusMenuOpen(false);
	}

	function addAttachment(type: MockPromptAttachmentType, path: string) {
		const name = folderDisplayName(path);
		setAttachments((current) => {
			if (current.some((attachment) => attachment.type === type && attachment.path === path)) {
				return current;
			}
			return [...current, { id: `${type}-${path}`, type, path, name }];
		});
	}

	function removeAttachment(id: string) {
		setAttachments((current) => current.filter((attachment) => attachment.id !== id));
	}

	async function handleUploadFile() {
		closePlusMenu();
		const file = await electroview.rpc?.request.selectAttachmentFile();
		if (file) {
			addAttachment("file", file);
		}
	}

	async function handleUploadFolder() {
		closePlusMenu();
		const folder = await electroview.rpc?.request.selectAttachmentFolder();
		if (folder) {
			addAttachment("directory", folder);
		}
	}

	function insertComposerToken(token: string) {
		const insertion = token.endsWith(" ") ? token : `${token} `;
		const textarea = textareaRef.current;
		setPrompt((current) => {
			if (!textarea) {
				return `${current}${insertion}`;
			}
			const start = textarea.selectionStart ?? current.length;
			const end = textarea.selectionEnd ?? current.length;
			return `${current.slice(0, start)}${insertion}${current.slice(end)}`;
		});
		closePlusMenu();
		requestAnimationFrame(() => textarea?.focus());
	}

	function handleSelectSlashCommand(command: MockSlashCommand) {
		insertComposerToken(`/${command.name}`);
	}

	function handleSelectSkill(skill: MockSkill) {
		insertComposerToken(`/${skill.id}`);
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

	async function handleChooseProject(folder: string) {
		if (isRunning) {
			return;
		}
		if (folder === projectFolder) {
			closeProjectMenu();
			return;
		}

		const started = await electroview.rpc?.request.startNewMockChat();
		if (started === false) {
			setTranscriptItems((current) => upsertErrorItem(current, "Wait for the active agent turn to finish before switching projects."));
			return;
		}

		resetConversationPane();
		setActiveSessionId(null);
		setContextMenu(null);
		setDeleteTargetId(null);
		setRunStatus("idle");
		setProjectFolder(folder);
		closeProjectMenu();
	}

	async function handleClearProject() {
		if (isRunning) {
			return;
		}
		if (!projectFolder) {
			closeProjectMenu();
			return;
		}

		const started = await electroview.rpc?.request.startNewMockChat();
		if (started === false) {
			setTranscriptItems((current) => upsertErrorItem(current, "Wait for the active agent turn to finish before leaving this project."));
			return;
		}

		resetConversationPane();
		setActiveSessionId(null);
		setContextMenu(null);
		setDeleteTargetId(null);
		setRunStatus("idle");
		setProjectFolder(null);
		closeProjectMenu();
	}

	async function handleSelectFolder() {
		if (isRunning) {
			return;
		}
		const folder = await electroview.rpc?.request.selectProjectFolder();
		if (folder) {
			await handleChooseProject(folder);
			return;
		}
		closeProjectMenu();
	}

	async function handleSend() {
		const trimmedPrompt = prompt.trim();
		if (!trimmedPrompt || isRunning) {
			return;
		}

		setStopReason(null);
		setPrompt("");
		setRunStatus("starting");
		pendingPromptProjectFolderRef.current = projectFolder;
		optimisticUserTextRef.current = trimmedPrompt;
		currentPlanKeyRef.current = `plan-${Date.now()}`;
		setTranscriptItems((current) =>
			upsertMessageItem(current, { id: `local-${Date.now()}`, role: "user", text: trimmedPrompt }),
		);
		void scrollToBottom();

		const response = await electroview.rpc?.request.startMockPrompt({
			prompt: trimmedPrompt,
			cwd: projectFolder,
			model,
			approvalMode,
			attachments: attachments.map(({ type, path, name }) => ({ type, path, name })),
		});
		if (!response?.accepted) {
			pendingPromptProjectFolderRef.current = undefined;
			optimisticUserTextRef.current = null;
			setRunStatus("idle");
			setTranscriptItems((current) => upsertErrorItem(current, "The mock agent is already running or the prompt was empty."));
			return;
		}
		setAttachments([]);
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

	function handleComposerScroll(event: UIEvent<HTMLTextAreaElement>) {
		if (promptOverlayRef.current) {
			promptOverlayRef.current.scrollTop = event.currentTarget.scrollTop;
		}
	}

	async function handlePermission(requestId: number | string, optionId: string) {
		let accepted = false;
		let failureMessage: string | null = null;
		try {
			accepted = (await electroview.rpc?.request.respondToMockPermission({ requestId, optionId })) ?? false;
			if (!accepted) {
				failureMessage = "Could not respond to the permission request. The mock agent turn may be stuck; try starting a new chat.";
			}
		} catch (error) {
			failureMessage = error instanceof Error ? error.message : "Failed to respond to the permission request.";
		}

		// Always clear pendingPermission, whether this succeeded or failed:
		// ApprovalPrompt has no cancel affordance of its own, so leaving it set
		// on failure would permanently freeze the composer with no way out.
		setPendingPermission((current) => (current?.requestId === requestId ? null : current));
		if (failureMessage) {
			setTranscriptItems((current) => upsertErrorItem(current, failureMessage));
		}
	}

	function handleDraftFeedback(text: string) {
		setPrompt(text);
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
			return;
		}
		const loadedSession = sessions.find((session) => session.sessionId === sessionId);
		setProjectFolder(
			sessionProjectFoldersRef.current.get(sessionId) ?? sessionProjectFolder(loadedSession),
		);
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
			className="app-gradient-background fixed inset-0 flex h-screen w-screen overflow-hidden text-foreground"
			onDoubleClick={() => electroview.rpc?.request.toggleMaximizeWindow()}
		>
			<div
				className="electrobun-webkit-app-region-drag fixed left-24 right-0 top-0 z-50 h-8"
				aria-hidden="true"
				onDoubleClick={(event) => {
					event.stopPropagation();
					void electroview.rpc?.request.toggleMaximizeWindow();
				}}
			/>
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
				className={cn(
					"electrobun-webkit-app-region-no-drag fixed z-10 inline-flex w-auto items-center gap-2 border border-[var(--app-sidebar-border)] bg-white/80 py-1 pl-1.5 text-muted-foreground shadow-[0_8px_24px_rgba(17,24,39,0.12)] backdrop-blur-2xl",
					shouldShowSessionContext
						? "min-h-14 max-w-[520px] rounded-[22px] pr-3"
						: "h-11 rounded-full pr-4",
				)}
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
				{shouldShowSessionContext ? (
					<div className="min-w-0 py-1">
						<div className="flex min-w-0 items-center gap-2">
							<span className="min-w-0 truncate text-[14px] font-semibold leading-5 text-foreground">{topBarTitle}</span>
							<MoreHorizontal className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
						</div>
						{topBarSubtitle ? (
							<div className="truncate text-[12px] font-medium leading-4 text-muted-foreground">{topBarSubtitle}</div>
						) : null}
					</div>
				) : (
					<>
						<img src={appIcon} alt="" className="size-6 shrink-0 rounded-full" />
						<span className="shrink-0 text-[14px] font-semibold text-foreground">{topBarTitle}</span>
					</>
				)}
			</div>

			<main className="electrobun-webkit-app-region-no-drag flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden px-6 pb-6 pt-20" aria-label="Workspace">
				<div className={cn("mx-auto flex min-h-0 w-full max-w-5xl flex-1 flex-col", hasConversation ? "" : "justify-center")}>
					<div className={cn("flex min-h-0 w-full flex-col", hasConversation ? "relative h-full" : "")}>
						{hasConversation ? (
							<div
								ref={transcriptScrollRef}
								className="app-scrollbar-transparent fixed bottom-0 right-0 top-0 overflow-y-auto overscroll-contain px-6 pt-24"
								style={{ left: `${renderedSidebarWidth}px` }}
							>
								<div ref={transcriptContentRef} className="mx-auto flex w-full max-w-3xl flex-col gap-4">
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
										if (item.type === "info") {
											return <InfoCard key={item.key} message={item.message} />;
										}
										return <ErrorCard key={item.key} message={item.message} />;
									})}
									{/* Reserves space for the composer overlay, which sits on top of this
									    scroll layer (see DESIGN.md §13). Lives inside the tracked content
									    (not a padding style on the scroll container) so useStickToBottom's
									    own resize observer reacts when the composer's height changes. */}
									<div aria-hidden="true" style={{ height: `${composerHeight + 32}px` }} />
								</div>
							</div>
						) : null}

						<div
							ref={composerContainerRef}
							className={cn("mx-auto w-full max-w-3xl shrink-0 overflow-visible rounded-[24px] border border-[rgba(0,0,0,0.1)] bg-[rgba(255,255,255,0.72)] shadow-[0_24px_70px_rgba(17,24,39,0.13)] backdrop-blur-2xl", hasConversation ? "relative z-10 mt-auto" : "")}
						>
							{pendingPermission ? (
								<ApprovalPrompt request={pendingPermission} onRespond={handlePermission} onDraftFeedback={handleDraftFeedback} />
							) : (
							<>
							<div className="px-6 pt-4">
								{attachments.length > 0 ? (
									<div className="mb-3 flex flex-wrap gap-2">
										{attachments.map((attachment) => (
											<AttachmentChip key={attachment.id} attachment={attachment} onRemove={removeAttachment} />
										))}
									</div>
								) : null}
								<div className="relative">
									<div
										ref={promptOverlayRef}
										aria-hidden="true"
										className="pointer-events-none absolute inset-0 overflow-hidden whitespace-pre-wrap break-words text-[22px] font-medium leading-6 text-foreground"
									>
										{renderComposerPreview(prompt)}
									</div>
									<textarea
										ref={textareaRef}
										value={prompt}
										placeholder="Do anything"
										aria-label="Message the mock agent"
										className="relative block w-full resize-none bg-transparent text-[22px] font-medium leading-6 text-transparent caret-foreground placeholder:text-muted-foreground/70 focus:outline-none"
										style={{ minHeight: COMPOSER_MIN_HEIGHT, maxHeight: COMPOSER_MAX_HEIGHT }}
										onChange={(event) => setPrompt(event.target.value)}
										onKeyDown={handleComposerKeyDown}
										onScroll={handleComposerScroll}
										disabled={isRunning}
									/>
								</div>
							</div>

							<div className="flex items-center gap-3 px-5 pb-3 pt-1">
								<div ref={plusMenuRef} className="relative">
									<IconButton
										label="Add to prompt"
										disabled={isRunning}
										aria-haspopup="menu"
										aria-expanded={isPlusMenuOpen}
										onClick={() => setIsPlusMenuOpen((value) => !value)}
									>
										<Plus className="size-5" strokeWidth={1.9} />
									</IconButton>

									{isPlusMenuOpen ? (
										<div
											role="menu"
											aria-label="Add to prompt"
											className="electrobun-webkit-app-region-no-drag app-scrollbar-transparent absolute bottom-[calc(100%+8px)] left-0 z-30 max-h-[420px] w-[320px] overflow-y-auto rounded-[24px] border border-[var(--app-sidebar-border)] bg-white/92 p-2 text-foreground shadow-[0_18px_46px_rgba(17,24,39,0.18)] backdrop-blur-2xl"
											onDoubleClick={(event) => event.stopPropagation()}
											onPointerDown={(event) => event.stopPropagation()}
										>
											<div className="flex flex-col gap-1">
												<ComposerMenuItem
													icon={<Paperclip className="size-4" strokeWidth={1.8} />}
													label="Upload file"
													onClick={() => void handleUploadFile()}
												/>
												<ComposerMenuItem
													icon={<Folder className="size-4" strokeWidth={1.8} />}
													label="Upload folder"
													onClick={() => void handleUploadFolder()}
												/>
												<ComposerMenuItem
													icon={<ListTodo className="size-4" strokeWidth={1.8} />}
													label="Plan mode"
													description="Coming soon"
													disabled
												/>
											</div>

											<div className="mt-2 border-t border-[var(--app-sidebar-border)] pt-2">
												<div className="px-2 pb-1 text-[12px] font-semibold text-muted-foreground">Slash commands</div>
												{slashCommands.length === 0 ? (
													<div className="flex h-10 items-center rounded-2xl px-2 text-[13px] font-medium text-muted-foreground">
														No slash commands available
													</div>
												) : (
													<div className="flex flex-col gap-1">
														{slashCommands.map((command) => (
															<ComposerMenuItem
																key={command.name}
																icon={<span className="font-mono text-[13px]">/</span>}
																label={command.name}
																description={command.description}
																onClick={() => handleSelectSlashCommand(command)}
															/>
														))}
													</div>
												)}
											</div>

											<div className="mt-2 border-t border-[var(--app-sidebar-border)] pt-2">
												<div className="px-2 pb-1 text-[12px] font-semibold text-muted-foreground">Skills</div>
												{skills.length === 0 ? (
													<div className="flex h-10 items-center rounded-2xl px-2 text-[13px] font-medium text-muted-foreground">
														No skills available
													</div>
												) : (
													<div className="flex flex-col gap-1">
														{skills.map((skill) => (
															<ComposerMenuItem
																key={skill.id}
																icon={<Sparkles className="size-4" strokeWidth={1.8} />}
																label={skill.name}
																description={skill.description}
																onClick={() => handleSelectSkill(skill)}
															/>
														))}
													</div>
												)}
											</div>
										</div>
									) : null}
								</div>
								<div ref={approvalMenuRef} className="relative">
									<button
										type="button"
										aria-haspopup="menu"
										aria-expanded={isApprovalMenuOpen}
										aria-label="Approval mode"
										disabled={isRunning}
										className="flex shrink-0 items-center gap-2 rounded-2xl px-2 py-2 text-[14px] font-semibold text-foreground transition-colors hover:bg-white/65 disabled:cursor-not-allowed disabled:opacity-45"
										onClick={() => setIsApprovalMenuOpen((value) => !value)}
									>
										<currentApprovalOption.icon className="size-4 text-[var(--app-accent)]" strokeWidth={1.8} />
										<span>{currentApprovalOption.label}</span>
										<ChevronDown className="size-4 text-muted-foreground" strokeWidth={1.8} />
									</button>

									{isApprovalMenuOpen ? (
										<div
											role="menu"
											aria-label="Approval mode"
											className="electrobun-webkit-app-region-no-drag absolute bottom-[calc(100%+8px)] left-0 z-30 w-[320px] rounded-[24px] border border-[var(--app-sidebar-border)] bg-white/92 p-3 text-foreground shadow-[0_18px_46px_rgba(17,24,39,0.18)] backdrop-blur-2xl"
											onDoubleClick={(event) => event.stopPropagation()}
											onPointerDown={(event) => event.stopPropagation()}
										>
											<div className="px-1 pb-2 text-[13px] font-semibold text-muted-foreground">
												How should mock actions be approved?
											</div>
											<div className="flex flex-col gap-0.5">
												{APPROVAL_MODE_OPTIONS.map((option) => {
													const isSelected = option.value === approvalMode;
													return (
														<button
															key={option.value}
															type="button"
															role="menuitemradio"
															aria-checked={isSelected}
															onClick={() => {
																setApprovalMode(option.value);
																setIsApprovalMenuOpen(false);
															}}
															className="flex w-full items-start gap-3 rounded-2xl px-2 py-2.5 text-left transition-colors hover:bg-muted/70 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--app-accent)]/35"
														>
															<option.icon className="mt-0.5 size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
															<span className="min-w-0 flex-1">
																<span className="block text-[14px] font-semibold text-foreground">{option.label}</span>
																<span className="mt-0.5 block text-[12px] leading-4 text-muted-foreground">
																	{option.description}
																</span>
															</span>
															{isSelected ? (
																<Check className="mt-0.5 size-4 shrink-0 text-foreground" strokeWidth={2} />
															) : null}
														</button>
													);
												})}
											</div>
										</div>
									) : null}
								</div>

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

							{hasConversation ? null : (
							<footer className="flex h-12 items-center justify-between bg-white/25 px-6 text-[14px] font-medium text-muted-foreground">
								<div ref={projectMenuRef} className="relative flex min-w-0 items-center">
									<button
										type="button"
										aria-haspopup="dialog"
										aria-expanded={isProjectMenuOpen}
										aria-label={projectFolder ? `Choose project, current project ${projectLabel(projectFolder)}` : "Choose project"}
										disabled={isRunning}
										className={cn(
											"flex min-w-0 items-center gap-2 rounded-2xl px-2 py-2 text-foreground transition-colors hover:bg-white/60",
											"focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--app-accent)]/35",
											isRunning ? "cursor-not-allowed opacity-45" : "",
										)}
										onClick={() => {
											if (isRunning) {
												return;
											}
											setIsProjectMenuOpen((value) => !value);
										}}
										title={projectFolder ?? "Choose project"}
									>
										<Folder className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
										<span className="max-w-48 truncate">{projectLabel(projectFolder)}</span>
									</button>

									{isProjectMenuOpen ? (
										<div
											role="dialog"
											aria-label="Choose project"
											className="electrobun-webkit-app-region-no-drag absolute bottom-[calc(100%+8px)] left-0 z-30 w-[336px] rounded-[24px] border border-[var(--app-sidebar-border)] bg-white/92 p-3 text-foreground shadow-[0_18px_46px_rgba(17,24,39,0.18)] backdrop-blur-2xl"
											onDoubleClick={(event) => event.stopPropagation()}
											onPointerDown={(event) => event.stopPropagation()}
										>
											<label className="flex h-10 items-center gap-2 rounded-[18px] px-2 text-muted-foreground">
												<Search className="size-4 shrink-0" strokeWidth={1.8} />
												<input
													ref={projectSearchRef}
													type="search"
													value={projectSearch}
													placeholder="Search projects"
													aria-label="Search projects"
													className="min-w-0 flex-1 bg-transparent text-[14px] font-medium text-foreground placeholder:text-muted-foreground focus:outline-none"
													onChange={(event) => setProjectSearch(event.target.value)}
												/>
											</label>

											<div className="app-scrollbar-transparent mt-2 max-h-56 overflow-y-auto pr-1">
												{filteredProjects.length === 0 ? (
													<div className="flex h-10 items-center rounded-2xl px-2 text-[14px] font-semibold text-muted-foreground">
														No matching projects
													</div>
												) : (
													<div className="flex flex-col gap-1">
														{filteredProjects.map((project) => {
															const isSelected = project.path === projectFolder;
															return (
																<button
																	key={project.path}
																	type="button"
																	title={project.path}
																	className={cn(
																		"flex h-10 w-full items-center gap-2 rounded-2xl px-2 text-left text-[14px] font-semibold transition-colors",
																		"focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--app-accent)]/35",
																		isSelected
																			? "bg-[var(--app-selected-surface)] text-foreground"
																			: "text-foreground hover:bg-muted/70",
																	)}
																	onClick={() => void handleChooseProject(project.path)}
																>
																	<Folder className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
																	<span className="min-w-0 flex-1 truncate">{project.name}</span>
																</button>
															);
														})}
													</div>
												)}
											</div>

											<div className="mt-2 border-t border-[var(--app-sidebar-border)] pt-2">
												<button
													type="button"
													className="flex h-10 w-full items-center gap-2 rounded-2xl px-2 text-left text-[14px] font-semibold text-foreground transition-colors hover:bg-muted/70 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--app-accent)]/35"
													onClick={() => void handleSelectFolder()}
												>
													<Plus className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
													<span className="min-w-0 flex-1 truncate">New project</span>
												</button>
												<button
													type="button"
													className="mt-1 flex h-10 w-full items-center gap-2 rounded-2xl px-2 text-left text-[14px] font-semibold text-foreground transition-colors hover:bg-muted/70 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--app-accent)]/35"
													onClick={() => void handleClearProject()}
												>
													<X className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
													<span className="min-w-0 flex-1 truncate">Don't work in a project</span>
												</button>
											</div>
										</div>
									) : null}
								</div>
								<div className="flex shrink-0 items-center gap-2 text-[12px]">
									<Circle className={cn("size-2 fill-current", statusDotClass(runStatus))} strokeWidth={0} />
									<span>{statusLabel(runStatus, stopReason)}</span>
								</div>
							</footer>
							)}
							</>
							)}
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

type IconButtonProps = Omit<ButtonHTMLAttributes<HTMLButtonElement>, "type"> & {
	children: ReactNode;
	label: string;
};

function IconButton({ children, label, className, ...props }: IconButtonProps) {
	return (
		<button
			type="button"
			aria-label={label}
			title={label}
			className={cn(
				"flex size-10 shrink-0 items-center justify-center rounded-2xl text-muted-foreground transition-colors hover:bg-white/65 hover:text-foreground disabled:cursor-not-allowed disabled:opacity-45",
				className,
			)}
			{...props}
		>
			{children}
		</button>
	);
}

function ComposerMenuItem({
	icon,
	label,
	description,
	disabled = false,
	onClick,
}: {
	icon: ReactNode;
	label: string;
	description?: string;
	disabled?: boolean;
	onClick?: () => void;
}) {
	return (
		<button
			type="button"
			role="menuitem"
			disabled={disabled}
			onClick={onClick}
			className="flex h-10 w-full items-center gap-2 rounded-2xl px-2 text-left text-[14px] font-semibold text-foreground transition-colors hover:bg-muted/70 disabled:cursor-not-allowed disabled:opacity-45 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--app-accent)]/35"
		>
			<span className="flex size-6 shrink-0 items-center justify-center text-muted-foreground">{icon}</span>
			<span className="min-w-0 flex-1 truncate">{label}</span>
			{description ? (
				<span className="max-w-[45%] shrink-0 truncate text-[13px] font-normal text-muted-foreground">{description}</span>
			) : null}
		</button>
	);
}

function AttachmentChip({ attachment, onRemove }: { attachment: AttachmentItem; onRemove: (id: string) => void }) {
	const Icon = attachment.type === "directory" ? Folder : Paperclip;
	return (
		<span className="inline-flex max-w-full items-center gap-1.5 rounded-full bg-muted/70 px-3 py-1.5 text-[13px] font-medium text-foreground">
			<Icon className="size-3.5 shrink-0 text-muted-foreground" strokeWidth={1.8} />
			<span className="max-w-48 truncate">{attachment.name}</span>
			<button
				type="button"
				aria-label={`Remove ${attachment.name}`}
				className="flex size-4 shrink-0 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-white/70 hover:text-foreground"
				onClick={() => onRemove(attachment.id)}
			>
				<X className="size-3" strokeWidth={2} />
			</button>
		</span>
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

const APPROVAL_DETAILS_PREVIEW_LENGTH = 220;

function approvalQuestion(request: MockPermissionRequest): string {
	const title = request.toolCall?.title;
	return title ? `Do you want me to go ahead with "${title}"?` : "Do you want me to proceed?";
}

function ApprovalPrompt({
	request,
	onRespond,
	onDraftFeedback,
}: {
	request: MockPermissionRequest;
	onRespond: (requestId: number | string, optionId: string) => Promise<void>;
	onDraftFeedback: (text: string) => void;
}) {
	const [highlightedIndex, setHighlightedIndex] = useState(0);
	const [isWritingFeedback, setIsWritingFeedback] = useState(false);
	const [feedbackText, setFeedbackText] = useState("");
	const [isDetailsExpanded, setIsDetailsExpanded] = useState(false);
	const [isSubmitting, setIsSubmitting] = useState(false);
	const feedbackInputRef = useRef<HTMLInputElement | null>(null);

	const details = toolContentText(request.toolCall?.content);
	const isDetailsLong = (details?.length ?? 0) > APPROVAL_DETAILS_PREVIEW_LENGTH;
	const visibleDetails = details && isDetailsLong && !isDetailsExpanded ? `${details.slice(0, APPROVAL_DETAILS_PREVIEW_LENGTH).trim()}…` : details;

	useEffect(() => {
		setHighlightedIndex(0);
		setIsWritingFeedback(false);
		setFeedbackText("");
		setIsDetailsExpanded(false);
		setIsSubmitting(false);
	}, [request.requestId]);

	useEffect(() => {
		if (isWritingFeedback) {
			feedbackInputRef.current?.focus();
		}
	}, [isWritingFeedback]);

	useEffect(() => {
		if (isWritingFeedback || isSubmitting) {
			return;
		}

		function handleKeyDown(event: globalThis.KeyboardEvent) {
			if (event.key === "ArrowDown") {
				event.preventDefault();
				setHighlightedIndex((index) => Math.min(index + 1, request.options.length - 1));
			} else if (event.key === "ArrowUp") {
				event.preventDefault();
				setHighlightedIndex((index) => Math.max(index - 1, 0));
			} else if (event.key === "Enter") {
				event.preventDefault();
				const option = request.options[highlightedIndex];
				if (option) {
					void submitOption(option.optionId);
				}
			}
		}

		document.addEventListener("keydown", handleKeyDown);
		return () => document.removeEventListener("keydown", handleKeyDown);
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [isWritingFeedback, isSubmitting, highlightedIndex, request.options]);

	async function submitOption(optionId: string) {
		setIsSubmitting(true);
		await onRespond(request.requestId, optionId);
	}

	function submitFeedback() {
		if (isSubmitting) {
			return;
		}
		const rejectOption =
			request.options.find((option) => option.kind?.startsWith("reject")) ?? request.options[request.options.length - 1];
		if (feedbackText.trim()) {
			onDraftFeedback(feedbackText.trim());
		}
		if (rejectOption) {
			void submitOption(rejectOption.optionId);
		}
	}

	return (
		<div className="px-6 py-5">
			<div className="text-[16px] font-semibold leading-6 text-foreground">{approvalQuestion(request)}</div>

			{visibleDetails ? (
				<div className="mt-3 rounded-2xl bg-muted/70 p-3">
					<pre className="overflow-x-auto whitespace-pre-wrap break-words font-mono text-[12px] leading-5 text-muted-foreground">
						{visibleDetails}
					</pre>
					{isDetailsLong ? (
						<button
							type="button"
							className="mt-1 text-[12px] font-semibold text-muted-foreground hover:text-foreground hover:underline"
							onClick={() => setIsDetailsExpanded((value) => !value)}
						>
							{isDetailsExpanded ? "Collapse" : "Expand"}
						</button>
					) : null}
				</div>
			) : null}

			<div className="mt-4 flex flex-col gap-1">
				{request.options.map((option, index) => (
					<button
						key={option.optionId}
						type="button"
						disabled={isSubmitting}
						className={cn(
							"flex items-center gap-3 rounded-2xl px-3 py-2.5 text-left text-[14px] font-medium text-foreground transition-colors disabled:cursor-not-allowed disabled:opacity-60",
							index === highlightedIndex ? "bg-muted/80" : "hover:bg-muted/50",
						)}
						onMouseEnter={() => setHighlightedIndex(index)}
						onClick={() => void submitOption(option.optionId)}
					>
						<span className="flex size-5 shrink-0 items-center justify-center rounded-full bg-white text-[12px] font-semibold text-muted-foreground shadow-sm">
							{index + 1}
						</span>
						<span className="min-w-0 flex-1 truncate">{option.name}</span>
					</button>
				))}
			</div>

			<div className="mt-2 border-t border-[var(--app-sidebar-border)] pt-2">
				{isWritingFeedback ? (
					<div className="flex items-center gap-2 px-1">
						<Pencil className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
						<input
							ref={feedbackInputRef}
							type="text"
							value={feedbackText}
							placeholder="Tell the agent what to do differently"
							aria-label="Tell the agent what to do differently"
							className="min-w-0 flex-1 bg-transparent text-[14px] text-foreground placeholder:text-muted-foreground focus:outline-none"
							disabled={isSubmitting}
							onChange={(event) => setFeedbackText(event.target.value)}
							onKeyDown={(event) => {
								if (event.key === "Enter") {
									event.preventDefault();
									submitFeedback();
								} else if (event.key === "Escape") {
									event.preventDefault();
									setIsWritingFeedback(false);
									setFeedbackText("");
								}
							}}
						/>
						<button
							type="button"
							disabled={isSubmitting}
							className="shrink-0 rounded-xl px-2 py-1 text-[13px] font-semibold text-muted-foreground transition-colors hover:bg-muted/70 disabled:cursor-not-allowed disabled:opacity-60"
							onClick={() => {
								setIsWritingFeedback(false);
								setFeedbackText("");
							}}
						>
							Skip
						</button>
						<button
							type="button"
							disabled={isSubmitting}
							className="shrink-0 rounded-xl bg-foreground px-3 py-1.5 text-[13px] font-semibold text-background transition-colors hover:bg-foreground/90 disabled:cursor-not-allowed disabled:opacity-60"
							onClick={submitFeedback}
						>
							Submit
						</button>
					</div>
				) : (
					<button
						type="button"
						disabled={isSubmitting}
						className="flex items-center gap-2 rounded-2xl px-3 py-2 text-left text-[14px] font-medium text-muted-foreground transition-colors hover:bg-muted/50 disabled:cursor-not-allowed disabled:opacity-60"
						onClick={() => setIsWritingFeedback(true)}
					>
						<Pencil className="size-4 shrink-0" strokeWidth={1.8} />
						<span>No, and tell the agent what to do differently</span>
					</button>
				)}
			</div>
		</div>
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

function InfoCard({ message }: { message: string }) {
	return (
		<div className="flex w-full max-w-3xl items-center gap-3 rounded-[20px] border border-[rgba(0,0,0,0.08)] bg-white/68 p-4 text-[14px] font-medium text-muted-foreground shadow-[0_12px_32px_rgba(17,24,39,0.07)]">
			<ShieldCheck className="size-4 shrink-0 text-[var(--app-accent)]" strokeWidth={1.9} />
			<span>{message}</span>
		</div>
	);
}

export default App;
