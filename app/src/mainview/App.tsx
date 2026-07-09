import {
	type ButtonHTMLAttributes,
	type KeyboardEvent,
	type MouseEvent,
	type PointerEvent,
	type ReactNode,
	type RefObject,
	type UIEvent,
	useEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { useAtom } from "jotai";
import { InspectorBackdrop } from "@/components/InspectorBackdrop";
import { TopBarGlassButton } from "@/components/TopBarGlassButton";
import { Markdown } from "@/lib/markdown";
import { useStickToBottom } from "use-stick-to-bottom";
import type { LucideIcon } from "lucide-react";
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { electroview } from "@/lib/electrobun";
import { ICONS } from "@/lib/icon-map";
import { resolveInspectorLayout } from "@/lib/layout";
import { expandedSessionGroupKeys, groupSessionsByProject } from "@/lib/sessionGroups";
import { cn } from "@/lib/utils";
import { useDrawerFocusTrap } from "@/lib/useDrawerFocusTrap";
import {
	WINDOW_FRAME_INSET,
	WINDOW_TRAFFIC_LIGHT_OFFSET,
	WINDOW_TOP_BAR_HEIGHT,
	WINDOW_TOP_CONTROL_SIZE,
	WINDOW_TOP_CONTROL_TOP,
} from "@shared/windowChrome";
import { REVIEW_PANE_DEFAULT_WIDTH, ReviewPane } from "@/ReviewPane";
import { SettingsDialog } from "@/SettingsDialog";
import { isDashboardPinnedAtom, isSidebarCollapsedAtom, sidebarWidthAtom } from "@/state/ui";
import { segmentTranscript } from "@/transcript/segments";
import { WorkingSection } from "@/transcript/WorkingSection";
import {
	APPROVAL_MODE_LABELS,
	type ApprovalModeId,
	type AgentUpdate,
	type AgentUpdateMessage,
	type AgentConfigOption,
	type AgentContentBlock,
	type AgentMessageUpdate,
	type AgentModelId,
	type AgentPermissionRequest,
	type AgentPlanItem,
	type AgentPromptAttachment,
	type AgentPromptAttachmentType,
	type AgentRunStatus,
	type AgentSessionSummary,
	type AgentSkill,
	type AgentSlashCommand,
	type AgentToolCall,
	type AgentUsage,
	type ProjectGitStatus,
} from "@shared/rpc";

const SIDEBAR_MIN_WIDTH = 260;
const SIDEBAR_MAX_WIDTH = 420;
const FRAME_INSET = WINDOW_FRAME_INSET;
const SIDEBAR_TOP_BAR_HEIGHT = 44;
const SIDEBAR_COLLAPSE_BUTTON_SIZE = 20;
const SIDEBAR_COLLAPSE_BUTTON_RIGHT_INSET = 16;
const FRAME_TOP_CONTROL_TOP = WINDOW_TOP_CONTROL_TOP;
const FRAME_TOP_CONTROL_SIZE = WINDOW_TOP_CONTROL_SIZE;
const FRAME_TOP_BAR_HEIGHT = WINDOW_TOP_BAR_HEIGHT;
const FRAME_TOP_GRADIENT_HEIGHT = FRAME_TOP_BAR_HEIGHT;
const FRAME_TOP_CONTROL_GAP = 6;
const MAC_TRAFFIC_LIGHT_CLUSTER_WIDTH = 64;
const FRAME_COLLAPSED_LEFT_CONTROLS =
	WINDOW_TRAFFIC_LIGHT_OFFSET.x + MAC_TRAFFIC_LIGHT_CLUSTER_WIDTH + FRAME_TOP_CONTROL_GAP;
const WORKSPACE_SIDEBAR_CLEARANCE = 32;
// Taller idle/empty composer (~150px total with the toolbar row) to match
// the reference composer's generous vertical padding around the
// placeholder, rather than a tight single-line input.
const COMPOSER_MIN_HEIGHT = 72;
const COMPOSER_MAX_HEIGHT = 192;
const DASHBOARD_REFRESH_DEBOUNCE_MS = 500;
const DASHBOARD_RESERVED_WIDTH_REM = 24;
const AGENT_SCROLL_INDICATOR_LEFT_INSET = -28;
const AGENT_SCROLL_INDICATOR_MIN_RAIL_HEIGHT = 132;
const AGENT_SCROLL_INDICATOR_MAX_RAIL_HEIGHT = 220;
const AGENT_SCROLL_INDICATOR_MIN_THUMB_HEIGHT = 48;
// DESIGN.md: "Review should preserve at least a 520px workspace; hide the
// Review toggle when the window cannot fit the workspace... even after
// sidebar collapse."
const MIN_WORKSPACE_WIDTH_WITH_REVIEW = 520;

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
		description: "Always ask before applying edits or running agent actions.",
		icon: ICONS.approvalAsk,
	},
	{
		value: "auto",
		label: APPROVAL_MODE_LABELS.auto,
		description: "Only ask for actions detected as potentially unsafe.",
		icon: ICONS.approvalAuto,
	},
	{
		value: "full-access",
		label: APPROVAL_MODE_LABELS["full-access"],
		description: "Run with Devin bypass permissions for this chat.",
		icon: ICONS.approvalFullAccess,
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

export type ToolCallView = AgentToolCall & {
	text?: string;
};

export type TranscriptItem =
	| { type: "message"; key: string; message: ChatMessage }
	| { type: "tool"; key: string; tool: ToolCallView }
	| { type: "error"; key: string; message: string }
	| { type: "thought"; key: string; thought: { id: string; text: string } };

type SessionContextMenu = {
	sessionId: string;
	x: number;
	y: number;
};

type RecentProject = {
	path: string;
	name: string;
};

type AttachmentItem = AgentPromptAttachment & { id: string };

// DESIGN.md/ARCHITECTURE.md: "Sending again while the active session is
// running queues an immutable structured composer snapshot in that
// session's in-memory FIFO queue. Queued prompts render compactly above
// the composer and can be removed before they start." Kept as plain
// in-memory React state (not persisted), matching native's in-memory
// per-session queue.
type QueuedPrompt = {
	id: string;
	text: string;
	attachments: AttachmentItem[];
	planMode: boolean;
};

// Shared glass chrome. Popovers/menus animate in with a 120ms ease-out
// fade+scale (DESIGN.md "Motion": subtle, functional, clarifies that the
// surface belongs to its trigger); the global reduced-motion CSS disables it.
const adaptivePopoverClass =
	"l5-adaptive-surface l5-glass-rim text-foreground animate-in fade-in-0 zoom-in-95 duration-quick ease-out";
const adaptiveDialogClass =
	"l5-adaptive-surface l5-glass-rim shadow-e3 animate-in fade-in-0 zoom-in-95 duration-quick ease-out";
const adaptiveChipClass =
	"l5-adaptive-chip electrobun-webkit-app-region-no-drag rounded-chip border border-border text-caption font-medium text-muted-foreground";
const adaptiveHoverClass = "hover:bg-muted/70";

function SidebarButton({ children, className, ...props }: SidebarButtonProps) {
	return (
		<button
			type="button"
			className={cn(
				"electrobun-webkit-app-region-no-drag flex items-center rounded-button text-left transition-colors",
				"focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35",
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

function remToPixels(rem: number) {
	if (typeof window === "undefined") {
		return rem * 16;
	}
	const rootFontSize = Number.parseFloat(window.getComputedStyle(document.documentElement).fontSize);
	return rem * (Number.isFinite(rootFontSize) ? rootFontSize : 16);
}

function contentText(content: AgentContentBlock): string {
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

function statusLabel(status: AgentRunStatus, stopReason: string | null) {
	if (status === "starting") return "Starting agent";
	if (status === "running") return "Agent is working";
	if (status === "stopping") return "Stopping agent";
	if (status === "error") return "Agent needs attention";
	if (stopReason) return `Stopped: ${stopReason}`;
	return "Ready";
}

function statusDotClass(status: string) {
	if (status === "completed") return "text-l5-success";
	if (status === "failed" || status === "error") return "text-l5-danger";
	if (status === "in_progress" || status === "running" || status === "starting" || status === "stopping") return "text-l5-accent";
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
			<span key={index} className="font-semibold text-l5-accent">
				{part}
			</span>
		) : (
			<span key={index}>{part}</span>
		),
	);
}

function sessionProjectFolder(session: AgentSessionSummary | undefined) {
	if (!session || session.isNoProject || isFolderlessProjectPath(session.cwd)) {
		return null;
	}
	return session.cwd.trim() || null;
}

function sessionTitle(session: AgentSessionSummary | undefined) {
	const title = session?.title.trim();
	return title || "New chat";
}

function sortSessions(sessions: AgentSessionSummary[]) {
	return [...sessions].sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
}

function dedupeSlashCommands(commands: AgentSlashCommand[]) {
	const seen = new Set<string>();
	return commands.filter((command) => {
		const key = command.name.trim();
		if (!key || seen.has(key)) {
			return false;
		}
		seen.add(key);
		return true;
	});
}

function upsertSession(sessions: AgentSessionSummary[], nextSession: AgentSessionSummary) {
	const withoutCurrent = sessions.filter((session) => session.sessionId !== nextSession.sessionId);
	return sortSessions([...withoutCurrent, nextSession]);
}

function isMissingRpcHandlerError(error: unknown, methodName: string) {
	return error instanceof Error && error.message.includes("has no handler") && error.message.includes(methodName);
}

function sessionActivityLabel(status: AgentRunStatus) {
	if (status === "starting" || status === "running") return "Chat is working";
	if (status === "stopping") return "Chat is stopping";
	if (status === "completed") return "Chat completed";
	return undefined;
}

function planSummary(items: AgentPlanItem[] | null) {
	if (!items || items.length === 0) {
		return "No active plan";
	}
	const activeItem = items.find((item) => item.status === "in_progress" || item.status === "running") ?? items[0];
	return `${activeItem.title} (${items.length})`;
}

function attachmentSummary(currentCount: number, lastSubmittedCount: number) {
	if (currentCount > 0) {
		return `${currentCount} attached`;
	}
	if (lastSubmittedCount > 0) {
		return `${lastSubmittedCount} last submitted`;
	}
	return "No sources";
}

function gitStatusSummary(status: ProjectGitStatus | null) {
	if (!status) {
		return "Not loaded";
	}
	if (!status.ok) {
		return status.error ?? "Git unavailable";
	}
	const files = `${status.changedFiles} file${status.changedFiles === 1 ? "" : "s"}`;
	const lines = `+${status.additions} / -${status.deletions}`;
	return status.hasUntracked ? `${files}, ${lines}, untracked` : `${files}, ${lines}`;
}

function gitBranchSummary(status: ProjectGitStatus | null) {
	if (!status) {
		return "Unknown";
	}
	if (!status.ok) {
		return "Not a git repo";
	}
	return status.isDetached ? `Detached at ${status.branch}` : status.branch;
}

function shouldRefreshGitAfterTool(tool: AgentToolCall) {
	const kind = tool.kind.toLowerCase();
	const title = tool.title.toLowerCase();
	const contentKinds = (tool.content ?? [])
		.map((entry) => (entry && typeof entry === "object" ? String((entry as Record<string, unknown>).type ?? "") : ""))
		.map((type) => type.toLowerCase());
	return (
		kind.includes("terminal") ||
		kind.includes("diff") ||
		title.includes("terminal") ||
		title.includes("diff") ||
		contentKinds.some((type) => type === "terminal" || type === "diff")
	);
}

// DESIGN.md "Sidebar": state precedence is awaiting permission, running,
// successful completion, then idle (no indicator).
function SessionActivityIndicator({ status, isAwaitingPermission }: { status: AgentRunStatus; isAwaitingPermission: boolean }) {
	if (isAwaitingPermission) {
		return (
			<span
				aria-label="Chat is awaiting your response"
				className="ml-auto flex size-5 shrink-0 items-center justify-center text-l5-warning"
			>
				<ICONS.awaitingPermission className="size-4" strokeWidth={2} />
			</span>
		);
	}
	if (status === "starting" || status === "running" || status === "stopping") {
		return (
			<span
				aria-label={sessionActivityLabel(status)}
				className="ml-auto flex size-5 shrink-0 items-center justify-center text-muted-foreground"
			>
				<ICONS.loading className="size-4 animate-spin" strokeWidth={2} />
			</span>
		);
	}
	if (status === "completed") {
		return (
			<span
				aria-label={sessionActivityLabel(status)}
				className="ml-auto flex size-5 shrink-0 items-center justify-center text-l5-success"
			>
				<ICONS.completed className="size-4" strokeWidth={2} />
			</span>
		);
	}
	return null;
}

function App() {
	const [isSidebarCollapsed, setIsSidebarCollapsed] = useAtom(isSidebarCollapsedAtom);
	const [sidebarWidth, setSidebarWidth] = useAtom(sidebarWidthAtom);
	const [isDashboardPinned, setIsDashboardPinned] = useAtom(isDashboardPinnedAtom);
	const [prompt, setPrompt] = useState("");
	const [projectFolder, setProjectFolder] = useState<string | null>(null);
	const [isProjectMenuOpen, setIsProjectMenuOpen] = useState(false);
	const [projectSearch, setProjectSearch] = useState("");
	const [model, setModel] = useState<AgentModelId>("");
	const [approvalMode, setApprovalMode] = useState<ApprovalModeId>("ask");
	const [transcriptItems, setTranscriptItems] = useState<TranscriptItem[]>([]);
	const [usage, setUsage] = useState<AgentUsage | null>(null);
	const [sessions, setSessions] = useState<AgentSessionSummary[]>([]);
	const [rememberedExpandedGroups, setRememberedExpandedGroups] = useState<Set<string>>(() => new Set());
	const [activeSessionId, setActiveSessionId] = useState<string | null>(null);
	const [contextMenu, setContextMenu] = useState<SessionContextMenu | null>(null);
	const [deleteTargetId, setDeleteTargetId] = useState<string | null>(null);
	const [isSettingsOpen, setIsSettingsOpen] = useState(false);
	const [runStatus, setRunStatus] = useState<AgentRunStatus>("idle");
	const [stopReason, setStopReason] = useState<string | null>(null);
	const [pendingPermission, setPendingPermission] = useState<AgentPermissionRequest | null>(null);
	const [isPlanModeEnabled, setIsPlanModeEnabled] = useState(false);
	const [pendingPlanEscalation, setPendingPlanEscalation] = useState<{ planText: string } | null>(null);
	const [isPlusMenuOpen, setIsPlusMenuOpen] = useState(false);
	const [isApprovalMenuOpen, setIsApprovalMenuOpen] = useState(false);
	const [slashCommands, setSlashCommands] = useState<AgentSlashCommand[]>([]);
	const [skills, setSkills] = useState<AgentSkill[]>([]);
	const [agentConfigOptions, setAgentConfigOptions] = useState<AgentConfigOption[]>([]);
	const [attachments, setAttachments] = useState<AttachmentItem[]>([]);
	const [lastSubmittedAttachmentCount, setLastSubmittedAttachmentCount] = useState(0);
	const [queuedPrompts, setQueuedPrompts] = useState<QueuedPrompt[]>([]);
	const queuedPromptsRef = useRef<QueuedPrompt[]>([]);
	const planModeSendRef = useRef(false);
	const transcriptItemsRef = useRef<TranscriptItem[]>([]);
	const planTurnStartIndexRef = useRef(0);
	const [gitStatus, setGitStatus] = useState<ProjectGitStatus | null>(null);
	const [isGitStatusRefreshing, setIsGitStatusRefreshing] = useState(false);
	const [isReviewOpen, setIsReviewOpen] = useState(false);
	const [inspectorOpenedAt, setInspectorOpenedAt] = useState({ dashboard: 0, review: 0 });
	// Not persisted across opens/relaunches by design (DESIGN.md "Review
	// Panel": "user-resizable... for the current open interaction only. Do
	// not persist width or open state.").
	const [reviewPaneWidth, setReviewPaneWidth] = useState(REVIEW_PANE_DEFAULT_WIDTH);
	const [planItems, setPlanItems] = useState<AgentPlanItem[] | null>(null);
	const [isPlanPopoverOpen, setIsPlanPopoverOpen] = useState(false);
	const [composerStatus, setComposerStatus] = useState<string | null>(null);
	const [composerProjectBranch, setComposerProjectBranch] = useState<string | null>(null);
	const [composerHeight, setComposerHeight] = useState(224);
	const [viewportWidth, setViewportWidth] = useState(() => (typeof window === "undefined" ? 1280 : window.innerWidth));
	const [isTranscriptScrolled, setIsTranscriptScrolled] = useState(false);
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
	const planPopoverRef = useRef<HTMLDivElement | null>(null);
	const composerStatusTimerRef = useRef<number | null>(null);
	const dashboardDrawerRef = useRef<HTMLElement | null>(null);
	const gitRefreshTimerRef = useRef<number | null>(null);
	const projectFolderRef = useRef<string | null>(null);
	const activeSessionIdRef = useRef<string | null>(null);
	const expandedSidebarWidth = clampSidebarWidth(sidebarWidth);
	const workspaceContentLeftInset = isSidebarCollapsed
		? 0
		: FRAME_INSET + expandedSidebarWidth + WORKSPACE_SIDEBAR_CLEARANCE;
	const sidebarToggleSize = isSidebarCollapsed ? FRAME_TOP_CONTROL_SIZE : SIDEBAR_COLLAPSE_BUTTON_SIZE;
	const sidebarToggleLeft = isSidebarCollapsed
		? FRAME_COLLAPSED_LEFT_CONTROLS
		: FRAME_INSET + expandedSidebarWidth - SIDEBAR_COLLAPSE_BUTTON_RIGHT_INSET - SIDEBAR_COLLAPSE_BUTTON_SIZE;
	const sidebarToggleTop = isSidebarCollapsed
		? FRAME_TOP_CONTROL_TOP
		: FRAME_INSET + (SIDEBAR_TOP_BAR_HEIGHT - SIDEBAR_COLLAPSE_BUTTON_SIZE) / 2;
	const currentApprovalOption =
		APPROVAL_MODE_OPTIONS.find((option) => option.value === approvalMode) ?? APPROVAL_MODE_OPTIONS[0];
	const modelConfigOption = agentConfigOptions.find((option) => option.id === "model");
	const modelOptions = modelConfigOption?.options?.map((option) => ({ value: option.value, label: option.name })) ?? [];
	const selectedModel = model || modelConfigOption?.currentValue || modelOptions[0]?.value || "";
	const isRunning = runStatus === "starting" || runStatus === "running" || runStatus === "stopping";
	const isStopping = runStatus === "stopping";
	const hasConversation = transcriptItems.length > 0;
	const segments = useMemo(() => segmentTranscript(transcriptItems), [transcriptItems]);
	const sessionGroups = useMemo(() => groupSessionsByProject(sessions), [sessions]);
	const visibleSessionGroupKeys = useMemo(
		() => expandedSessionGroupKeys(sessionGroups, rememberedExpandedGroups, projectFolder),
		[projectFolder, rememberedExpandedGroups, sessionGroups],
	);
	const activeSessionStatus = activeSessionId ? runStatus : "idle";
	const activeSession = activeSessionId ? sessions.find((session) => session.sessionId === activeSessionId) : undefined;
	const deleteTarget = deleteTargetId ? sessions.find((session) => session.sessionId === deleteTargetId) : undefined;
	const menuSession = contextMenu ? sessions.find((session) => session.sessionId === contextMenu.sessionId) : undefined;
	const firstUserMessage = transcriptItems.find(
		(item): item is Extract<TranscriptItem, { type: "message" }> =>
			item.type === "message" && item.message.role === "user",
	);
	const activeSessionTitle = sessionTitle(activeSession);
	const isDashboardEligible = Boolean(activeSessionId && projectFolder);
	const dashboardReservedWidthPixels = remToPixels(DASHBOARD_RESERVED_WIDTH_REM);
	// Available for New Chat with a selected project and for project-backed
	// active sessions, matching native's Review eligibility.
	const isReviewEligible = Boolean(projectFolder);
	const inspectorLayout = resolveInspectorLayout({
		viewportWidth,
		sidebarExpanded: !isSidebarCollapsed,
		sidebarWidth: FRAME_INSET + expandedSidebarWidth + WORKSPACE_SIDEBAR_CLEARANCE,
		dashboardOpen: isDashboardEligible && isDashboardPinned,
		reviewOpen: isReviewEligible && isReviewOpen,
		dashboardOpenedAt: inspectorOpenedAt.dashboard,
		reviewOpenedAt: inspectorOpenedAt.review,
		dashboardWidth: dashboardReservedWidthPixels,
		reviewWidth: reviewPaneWidth,
		minimumWorkspaceWidth: MIN_WORKSPACE_WIDTH_WITH_REVIEW,
	});
	const dashboardReservedWidth = inspectorLayout.dashboard === "panel" ? dashboardReservedWidthPixels : 0;
	const reviewReservedWidth = inspectorLayout.review === "panel" ? reviewPaneWidth : 0;
	const isReviewVisible = inspectorLayout.review !== "closed";
	const topBarTitle =
		activeSessionTitle === "New chat" && firstUserMessage
			? compactTitle(firstUserMessage.message.text)
			: activeSession
				? activeSessionTitle
				: "Level5";
	// Durable, independently-tracked list of the 10 most-recently-opened
	// project folders (see AGENTS.md / RecentProjectStore), not merely
	// derived from sessions -- a folder opened but never chatted in still
	// shows up here and survives a relaunch.
	const [recentProjects, setRecentProjects] = useState<RecentProject[]>([]);
	const filteredProjects = useMemo(() => {
		const search = projectSearch.trim().toLowerCase();
		if (!search) {
			return recentProjects;
		}
		return recentProjects.filter(
			(project) => project.name.toLowerCase().includes(search) || project.path.toLowerCase().includes(search),
		);
	}, [projectSearch, recentProjects]);
	useDrawerFocusTrap(dashboardDrawerRef, inspectorLayout.dashboard === "drawer", () => setIsDashboardPinned(false));

	useEffect(() => {
		if (inspectorLayout.shouldCollapseSidebar && !isSidebarCollapsed) {
			setIsSidebarCollapsed(true);
		}
		if (inspectorLayout.closedForFit === "dashboard") {
			setIsDashboardPinned(false);
		} else if (inspectorLayout.closedForFit === "review") {
			setIsReviewOpen(false);
		}
	}, [inspectorLayout.closedForFit, inspectorLayout.shouldCollapseSidebar, isSidebarCollapsed, setIsDashboardPinned, setIsSidebarCollapsed]);

	async function refreshProjectGitStatus(cwd = projectFolderRef.current) {
		if (!cwd || !activeSessionIdRef.current) {
			setGitStatus(null);
			return;
		}
		setIsGitStatusRefreshing(true);
		try {
			const nextStatus = await electroview.rpc?.request.getProjectGitStatus({ cwd });
			if (cwd === projectFolderRef.current) {
				setGitStatus(nextStatus ?? { ok: false, error: "Git status is unavailable." });
			}
		} catch (error) {
			if (cwd === projectFolderRef.current) {
				setGitStatus({
					ok: false,
					error: error instanceof Error ? error.message : "Failed to read git status.",
				});
			}
		} finally {
			if (cwd === projectFolderRef.current) {
				setIsGitStatusRefreshing(false);
			}
		}
	}

	function scheduleGitStatusRefresh() {
		if (!projectFolderRef.current || !activeSessionIdRef.current) {
			return;
		}
		if (gitRefreshTimerRef.current !== null) {
			window.clearTimeout(gitRefreshTimerRef.current);
		}
		gitRefreshTimerRef.current = window.setTimeout(() => {
			gitRefreshTimerRef.current = null;
			void refreshProjectGitStatus();
		}, DASHBOARD_REFRESH_DEBOUNCE_MS);
	}

	useEffect(() => {
		projectFolderRef.current = projectFolder;
		activeSessionIdRef.current = activeSessionId;
	}, [activeSessionId, projectFolder]);

	useEffect(() => {
		queuedPromptsRef.current = queuedPrompts;
	}, [queuedPrompts]);

	// Project-context changes close Review (DESIGN.md "Review Panel"); the
	// pane itself re-fetches on cwd change, but a different project should
	// not silently keep showing a stale open pane over new chat state.
	useEffect(() => {
		setIsReviewOpen(false);
	}, [projectFolder]);

	// The composer footer's branch chip tracks the *selected* project for the
	// next new chat, independent of the active session's own Dashboard git
	// status (fetched separately above only while a session is active and the
	// dashboard is pinned) -- kept as two separate states/effects on purpose,
	// since the selected project and the active session's project can differ.
	useEffect(() => {
		if (!projectFolder) {
			setComposerProjectBranch(null);
			return;
		}
		let cancelled = false;
		void (async () => {
			try {
				const status = await electroview.rpc?.request.getProjectGitStatus({ cwd: projectFolder });
				if (!cancelled) {
					setComposerProjectBranch(status?.ok ? status.branch : null);
				}
			} catch {
				if (!cancelled) {
					setComposerProjectBranch(null);
				}
			}
		})();
		return () => {
			cancelled = true;
		};
	}, [projectFolder]);

	useEffect(() => {
		function updateViewportWidth() {
			setViewportWidth(window.innerWidth);
		}

		updateViewportWidth();
		window.addEventListener("resize", updateViewportWidth);
		return () => window.removeEventListener("resize", updateViewportWidth);
	}, []);

	useEffect(() => {
		if (!hasConversation) {
			setIsTranscriptScrolled(false);
			return;
		}
		const element = transcriptScrollRef.current;
		if (!element) {
			return;
		}

		function updateScrolled() {
			setIsTranscriptScrolled((current) => {
				const next = element!.scrollTop > 0;
				return current === next ? current : next;
			});
		}

		updateScrolled();
		element.addEventListener("scroll", updateScrolled, { passive: true });
		return () => element.removeEventListener("scroll", updateScrolled);
	}, [transcriptScrollRef, hasConversation]);

	useEffect(() => {
		if (!isDashboardEligible) {
			setGitStatus(null);
			setIsGitStatusRefreshing(false);
			return;
		}
		if (isDashboardPinned) {
			void refreshProjectGitStatus(projectFolder);
		}
		// The dashboard intentionally refreshes on run status edges as a cheap
		// event-driven proxy for file changes made during a turn.
	}, [activeSessionId, isDashboardEligible, isDashboardPinned, projectFolder, runStatus]);

	useEffect(() => {
		return () => {
			if (gitRefreshTimerRef.current !== null) {
				window.clearTimeout(gitRefreshTimerRef.current);
			}
			if (composerStatusTimerRef.current !== null) {
				window.clearTimeout(composerStatusTimerRef.current);
			}
		};
	}, []);

	// DESIGN.md "Keyboard": "Every major action should have a shortcut."
	useEffect(() => {
		function handleKeyDown(event: globalThis.KeyboardEvent) {
			if (!(event.metaKey || event.ctrlKey)) {
				return;
			}
			const key = event.key.toLowerCase();
			if (key === "n" && !event.shiftKey) {
				event.preventDefault();
				void handleNewChat();
				return;
			}
			if (key === "b" && !event.shiftKey) {
				event.preventDefault();
				setIsSidebarCollapsed((value) => !value);
				return;
			}
			if (key === "d" && event.shiftKey && isDashboardEligible) {
				event.preventDefault();
				setIsDashboardPinned((value) => {
					const shouldOpen = !value;
					if (shouldOpen) {
						setInspectorOpenedAt((current) => ({ ...current, dashboard: Date.now() }));
						void refreshProjectGitStatus(projectFolder);
					}
					return shouldOpen;
				});
				return;
			}
			if (key === "r" && event.shiftKey && isReviewEligible) {
				event.preventDefault();
				setIsReviewOpen((value) => {
					const opening = !value;
					if (opening) setInspectorOpenedAt((current) => ({ ...current, review: Date.now() }));
					return opening;
				});
			}
		}

		document.addEventListener("keydown", handleKeyDown);
		return () => document.removeEventListener("keydown", handleKeyDown);
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [
		isDashboardEligible,
		isReviewEligible,
		projectFolder,
	]);

	useEffect(() => {
		if (!isPlanPopoverOpen) {
			return;
		}

		function closePopover() {
			setIsPlanPopoverOpen(false);
		}

		function handlePointerDown(event: globalThis.PointerEvent) {
			if (planPopoverRef.current?.contains(event.target as Node)) {
				return;
			}
			closePopover();
		}

		function handleKeyDown(event: globalThis.KeyboardEvent) {
			if (event.key === "Escape") {
				closePopover();
			}
		}

		document.addEventListener("pointerdown", handlePointerDown);
		document.addEventListener("keydown", handleKeyDown);
		return () => {
			document.removeEventListener("pointerdown", handlePointerDown);
			document.removeEventListener("keydown", handleKeyDown);
		};
	}, [isPlanPopoverOpen]);

	useEffect(() => {
		const handler = ({ sessionId, update }: AgentUpdateMessage) => {
			// Each project now runs its own concurrent agent process (see
			// AGENTS.md per-project process pool notes), so a background
			// project's activity arrives on this same channel. It must never
			// overwrite the banner or transcript for the session the user is
			// currently viewing -- the sidebar (refreshAgentSessions, sourced
			// from the durable cache) is background activity's only visible
			// effect until the user switches to that session.
			//
			// A "new chat"/"choose project" flow has no session id to compare
			// against yet: prepareAgentSession/startAgentPrompt's *push*
			// updates (status/session/config/slashCommands) can arrive before
			// their *RPC response* resolves and sets activeSessionId. Without
			// this, e.g. the model config pushed from initialize()/
			// session/new()'s response during project preparation would be
			// silently dropped (sessionId !== activeSessionIdRef.current,
			// which is still null) and the model selector would never
			// populate for that chat. pendingPromptProjectFolderRef marks
			// "we're mid-flight waiting for a brand-new session for this
			// project" (set by handleSend/handleChooseProject); since only
			// one such flow can be in-flight while there's no active session,
			// any update arriving during it is safely attributed as ours.
			const isOwnPendingUpdate =
				activeSessionIdRef.current === null &&
				pendingPromptProjectFolderRef.current !== undefined &&
				(update.kind !== "status" || (update.cwd ?? null) === (pendingPromptProjectFolderRef.current ?? null));

			// The backend's eager home-directory warm-up (module-bottom
			// `prepareSession({ cwd: null, ... })`, fired at boot before any
			// project is ever chosen) pushes its `config`/`slashCommands`
			// exactly like a real project selection would, but it never runs
			// through handleChooseProject/dispatchPrompt -- so
			// pendingPromptProjectFolderRef is never set for it and
			// isOwnPendingUpdate above is unconditionally false. Without this,
			// that push was silently dropped by the isForActiveSession gate
			// below, and the pull-based refreshComposerMenuData fallback
			// (listAgentSlashCommands/listAgentConfigOptions) independently
			// loses the same race against the backend's own async
			// available_commands_update/config_option_update notification
			// (see AgentAcpClient.listConfigOptions's awaitSetup comment) --
			// so the "+ " menu's slash commands never appeared before a
			// project was selected. Safe to accept unconditionally here:
			// with no active session AND nothing else pending, there is no
			// other in-flight flow this push could ambiguously belong to,
			// and config/slashCommands carry no session-identity
			// implications (unlike message/tool/plan), so no
			// setActiveSessionId adoption is needed alongside it.
			const isUntrackedWarmupUpdate =
				activeSessionIdRef.current === null &&
				pendingPromptProjectFolderRef.current === undefined &&
				(update.kind === "config" || update.kind === "slashCommands");

			// A session doesn't exist yet the moment initialize()'s response
			// pushes its config (emitted with an empty sessionId) -- only
			// adopt a real, non-empty session id as active.
			if (isOwnPendingUpdate && sessionId) {
				setActiveSessionId(sessionId);
				sessionProjectFoldersRef.current.set(sessionId, pendingPromptProjectFolderRef.current ?? null);
			}

			const isForActiveSession = sessionId === activeSessionIdRef.current || isOwnPendingUpdate || isUntrackedWarmupUpdate;

			if (update.kind === "status") {
				if (isForActiveSession) {
					setRunStatus(update.status);
				}
				void refreshAgentSessions();
				return;
			}

			if (!isForActiveSession) {
				if (update.kind === "stop" || update.kind === "error" || update.kind === "session") {
					void refreshAgentSessions();
				}
				return;
			}

			if (update.kind === "message") {
				applyMessageUpdate(update);
				return;
			}
			if (update.kind === "thought") {
				updateTranscriptItems((current) => upsertThoughtItem(current, { id: update.messageId, text: contentText(update.content) }));
				return;
			}
			if (update.kind === "plan") {
				// Plan state renders as the composer-adjacent Plan N/M chip
				// (see DESIGN.md "Prompt Composer"), never as a transcript row.
				setPlanItems(update.items);
				return;
			}
			if (update.kind === "tool") {
				updateTranscriptItems((current) => upsertToolItem(current, update.tool));
				if (shouldRefreshGitAfterTool(update.tool)) {
					scheduleGitStatusRefresh();
				}
				return;
			}
			if (update.kind === "usage") {
				setUsage({ used: update.used, size: update.size });
				return;
			}
			if (update.kind === "permission") {
				setPendingPermission(update.request);
				return;
			}
			if (update.kind === "config") {
				setAgentConfigOptions(update.options);
				const nextModel = update.options.find((option) => option.id === "model");
				setModel((current) => current || nextModel?.currentValue || nextModel?.options?.[0]?.value || "");
				return;
			}
			if (update.kind === "slashCommands") {
				setSlashCommands(dedupeSlashCommands(update.commands));
				return;
			}
			if (update.kind === "session") {
				setSessions((current) => upsertSession(current, update.session));
				setActiveSessionId(sessionId);
				if (pendingPromptProjectFolderRef.current !== undefined) {
					sessionProjectFoldersRef.current.set(sessionId, pendingPromptProjectFolderRef.current);
				}
				void refreshAgentSessions();
				return;
			}
			if (update.kind === "stop") {
				pendingPromptProjectFolderRef.current = undefined;
				setStopReason(update.stopReason);
				setRunStatus("completed");
				void refreshAgentSessions();
				if (planModeSendRef.current) {
					planModeSendRef.current = false;
					if (update.stopReason === "end_turn") {
						const items = transcriptItemsRef.current;
						const startIndex = planTurnStartIndexRef.current;
						let planText: string | null = null;
						for (let i = items.length - 1; i >= startIndex; i--) {
							const item = items[i];
							if (item.type === "message" && item.message.role === "agent" && item.message.text.trim() !== "") {
								planText = item.message.text;
								break;
							}
						}
						if (planText) {
							setPendingPlanEscalation({ planText });
						} else {
							showComposerStatus("Plan mode: no plan was returned. Try again.");
							dequeueNextPrompt();
						}
					} else {
						showComposerStatus("Plan mode: no plan was returned. Try again.");
						dequeueNextPrompt();
					}
					return;
				}
				dequeueNextPrompt();
				return;
			}
			if (update.kind === "error") {
				pendingPromptProjectFolderRef.current = undefined;
				updateTranscriptItems((current) => upsertErrorItem(current, update.message));
				setRunStatus("error");
				if (planModeSendRef.current) {
					planModeSendRef.current = false;
					dequeueNextPrompt();
					return;
				}
				dequeueNextPrompt();
				return;
			}
			if (update.kind === "info") {
				// Runtime diagnostics/audit notes (e.g. auto-approval) are never
				// transcript rows (see DESIGN.md "Chat"); shown as a transient
				// composer-adjacent status instead.
				showComposerStatus(update.message);
			}
		};

		const rpc = electroview.rpc;
		rpc?.addMessageListener("agentUpdate", handler);
		return () => rpc?.removeMessageListener("agentUpdate", handler);
	}, []);

	useEffect(() => {
		void refreshAgentSessions({ reportErrors: false });
		void refreshComposerMenuData();
		void refreshRecentProjects();
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

	// Note: no longer force-closed while running -- the composer (and its
	// attachment/approval-mode menus) stays interactive during an active
	// turn so the user can compose/queue the next prompt (see
	// QueuedPrompt/handleSend).

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

	/**
	 * Replays one cached AgentUpdate (from getSessionTranscript) into local
	 * state when a sidebar session is selected. Selecting a session is pure
	 * local retrieval -- no RPC to the agent runtime -- so this only
	 * reduces static already-known content; live-only signals (status,
	 * session, config, slashCommands, permission, info) are not meaningful
	 * to replay from a snapshot and are skipped.
	 */
	function applyHydratedUpdate(update: AgentUpdate) {
		if (update.kind === "message") {
			applyMessageUpdate(update);
			return;
		}
		if (update.kind === "thought") {
			updateTranscriptItems((current) => upsertThoughtItem(current, { id: update.messageId, text: contentText(update.content) }));
			return;
		}
		if (update.kind === "plan") {
			setPlanItems(update.items);
			return;
		}
		if (update.kind === "tool") {
			updateTranscriptItems((current) => upsertToolItem(current, update.tool));
			return;
		}
		if (update.kind === "usage") {
			setUsage({ used: update.used, size: update.size });
			return;
		}
		if (update.kind === "stop") {
			setStopReason(update.stopReason);
			return;
		}
		if (update.kind === "error") {
			updateTranscriptItems((current) => upsertErrorItem(current, update.message));
		}
	}

	function applyMessageUpdate(update: AgentMessageUpdate) {
		const text = contentText(update.content);
		if (update.role === "user" && optimisticUserTextRef.current === text) {
			optimisticUserTextRef.current = null;
			return;
		}

		updateTranscriptItems((current) => upsertMessageItem(current, { id: update.messageId, role: update.role, text }));
	}

	function mergeToolCall(current: ToolCallView | undefined, tool: AgentToolCall): ToolCallView {
		const nextTool = {
			...tool,
			text: toolContentText(tool.content),
		};
		if (!current) {
			return {
				...nextTool,
				title: nextTool.title || "Agent tool",
				kind: nextTool.kind || "tool",
				status: nextTool.status || "pending",
			};
		}
		return {
			...current,
			toolCallId: nextTool.toolCallId || current.toolCallId,
			title: nextTool.title && nextTool.title !== "Agent tool" ? nextTool.title : current.title,
			kind: nextTool.kind && nextTool.kind !== "tool" ? nextTool.kind : current.kind,
			status: nextTool.status || current.status,
			content: nextTool.content ?? current.content,
			locations: nextTool.locations ?? current.locations,
			rawInput: nextTool.rawInput ?? current.rawInput,
			text: nextTool.text ?? current.text,
		};
	}

	function upsertMessageItem(current: TranscriptItem[], nextMessage: ChatMessage): TranscriptItem[] {
		const messageId = nextMessage.id.trim();
		const exactIndex = messageId
			? current.findIndex(
					(item) => item.type === "message" && item.message.id === messageId && item.message.role === nextMessage.role,
				)
			: -1;
		const lastIndex = current.length - 1;
		const lastItem = current[lastIndex];
		const contiguousIndex = lastItem?.type === "message" && lastItem.message.role === nextMessage.role ? lastIndex : -1;
		const index = exactIndex >= 0 ? exactIndex : contiguousIndex;
		if (index < 0) {
			return [...current, { type: "message", key: `message-${nextMessage.role}-${messageId || Date.now()}`, message: { ...nextMessage, id: messageId } }];
		}
		return current.map((item, itemIndex) =>
			itemIndex === index && item.type === "message"
				? { ...item, message: { ...item.message, text: `${item.message.text}${nextMessage.text}` } }
				: item,
		);
	}

	function upsertThoughtItem(current: TranscriptItem[], nextThought: { id: string; text: string }): TranscriptItem[] {
		const thoughtId = nextThought.id.trim();
		const exactIndex = thoughtId ? current.findIndex((item) => item.type === "thought" && item.thought.id === thoughtId) : -1;
		const lastIndex = current.length - 1;
		const lastItem = current[lastIndex];
		const contiguousIndex = lastItem?.type === "thought" ? lastIndex : -1;
		const index = exactIndex >= 0 ? exactIndex : contiguousIndex;
		if (index < 0) {
			return [...current, { type: "thought", key: `thought-${thoughtId || Date.now()}`, thought: { ...nextThought, id: thoughtId } }];
		}
		return current.map((item, itemIndex) =>
			itemIndex === index && item.type === "thought"
				? { ...item, thought: { ...item.thought, text: `${item.thought.text}${nextThought.text}` } }
				: item,
		);
	}

	function upsertToolItem(current: TranscriptItem[], tool: AgentToolCall): TranscriptItem[] {
		const index = current.findIndex((item) => item.type === "tool" && item.tool.toolCallId === tool.toolCallId);
		if (index < 0) {
			return [...current, {
				type: "tool",
				key: `tool-${tool.toolCallId}`,
				tool: mergeToolCall(undefined, tool),
			}];
		}
		return current.map((item, itemIndex) =>
			itemIndex === index && item.type === "tool" ? { ...item, tool: mergeToolCall(item.tool, tool) } : item,
		);
	}

	function upsertErrorItem(current: TranscriptItem[], message: string): TranscriptItem[] {
		return [...current.filter((item) => item.type !== "error"), { type: "error", key: `error-${Date.now()}`, message }];
	}

	/** Transient composer-adjacent status (e.g. auto-approval notices); never a transcript row. */
	function showComposerStatus(message: string) {
		setComposerStatus(message);
		if (composerStatusTimerRef.current !== null) {
			window.clearTimeout(composerStatusTimerRef.current);
		}
		composerStatusTimerRef.current = window.setTimeout(() => {
			composerStatusTimerRef.current = null;
			setComposerStatus(null);
		}, 4000);
	}
	/** Wrapper that keeps transcriptItemsRef in sync for same-batch reads (e.g. plan-mode stop handler). */
	function updateTranscriptItems(updater: (current: TranscriptItem[]) => TranscriptItem[]) {
		setTranscriptItems((current) => {
			const next = updater(current);
			transcriptItemsRef.current = next;
			return next;
		});
	}

	async function refreshAgentSessions({ reportErrors = true }: { reportErrors?: boolean } = {}) {
		try {
			const nextSessions = await electroview.rpc?.request.listAgentSessions();
			if (nextSessions) {
				setSessions(sortSessions(nextSessions));
			}
		} catch (error) {
			if (isMissingRpcHandlerError(error, "listAgentSessions")) {
				return;
			}
			if (!reportErrors) {
				return;
			}
			updateTranscriptItems((current) =>
				upsertErrorItem(current, error instanceof Error ? error.message : "Failed to refresh chats."),
			);
		}
	}

	async function refreshRecentProjects() {
		try {
			const next = await electroview.rpc?.request.listRecentProjects();
			if (next) {
				setRecentProjects(next.map((project) => ({ path: project.path, name: project.displayName })));
			}
		} catch (error) {
			if (isMissingRpcHandlerError(error, "listRecentProjects")) {
				return;
			}
			// Non-fatal: the project picker simply shows an empty recents list.
		}
	}

	async function refreshComposerMenuData() {
		try {
			const [nextSlashCommands, nextSkills, nextConfigOptions] = await Promise.all([
				electroview.rpc?.request.listAgentSlashCommands() ?? Promise.resolve(undefined),
				electroview.rpc?.request.listAgentSkills() ?? Promise.resolve(undefined),
				// Pull-based fallback: the backend's eager home-directory
				// warm-up (so the model selector works even with no project
				// selected) pushes its "config" agentUpdate before this
				// webview has necessarily mounted its listener, which would
				// otherwise silently drop it (see listAgentConfigOptions).
				electroview.rpc?.request.listAgentConfigOptions() ?? Promise.resolve(undefined),
			]);
			if (nextSlashCommands) {
				setSlashCommands(dedupeSlashCommands(nextSlashCommands));
			}
			if (nextSkills) {
				setSkills(nextSkills);
			}
			if (nextConfigOptions && nextConfigOptions.length > 0) {
				setAgentConfigOptions(nextConfigOptions);
				const nextModel = nextConfigOptions.find((option) => option.id === "model");
				setModel((current) => current || nextModel?.currentValue || nextModel?.options?.[0]?.value || "");
			}
		} catch (error) {
			if (
				isMissingRpcHandlerError(error, "listAgentSlashCommands") ||
				isMissingRpcHandlerError(error, "listAgentSkills") ||
				isMissingRpcHandlerError(error, "listAgentConfigOptions")
			) {
				return;
			}
			// Non-fatal: the plus menu simply shows empty slash command/skill groups.
		}
	}

	function resetConversationPane() {
		optimisticUserTextRef.current = null;
		pendingPromptProjectFolderRef.current = undefined;
		// Inspectors are explicitly invoked per session context. Clearing this
		// state prevents Dashboard from reappearing when a replacement session
		// becomes eligible after a new-chat, project, or session transition.
		setIsDashboardPinned(false);
		setPrompt("");
		updateTranscriptItems(() => []);
		setAttachments([]);
		setLastSubmittedAttachmentCount(0);
		setPlanItems(null);
		setIsPlanPopoverOpen(false);
		setStopReason(null);
		setPendingPermission(null);
		setPendingPlanEscalation(null);
		setUsage(null);
	}

	function closeProjectMenu() {
		setIsProjectMenuOpen(false);
		setProjectSearch("");
	}

	function closePlusMenu() {
		setIsPlusMenuOpen(false);
	}

	function addAttachment(type: AgentPromptAttachmentType, path: string) {
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

	function handleSelectSlashCommand(command: AgentSlashCommand) {
		insertComposerToken(`/${command.name}`);
	}

	function handleSelectSkill(skill: AgentSkill) {
		insertComposerToken(`/${skill.id}`);
	}

	function handleResizePointerDown(event: PointerEvent<HTMLDivElement>) {
		if (isSidebarCollapsed) {
			return;
		}

		event.preventDefault();
		event.currentTarget.setPointerCapture(event.pointerId);
		setSidebarWidth(clampSidebarWidth(event.clientX - FRAME_INSET));
	}

	function handleResizePointerMove(event: PointerEvent<HTMLDivElement>) {
		if (!event.currentTarget.hasPointerCapture(event.pointerId)) {
			return;
		}

		setSidebarWidth(clampSidebarWidth(event.clientX - FRAME_INSET));
	}

	async function handleChooseProject(folder: string) {
		if (isRunning) {
			return;
		}
		if (folder === projectFolder) {
			closeProjectMenu();
			return;
		}

		const started = await electroview.rpc?.request.startNewAgentChat();
		if (started === false) {
			updateTranscriptItems((current) => upsertErrorItem(current, "Wait for the active agent turn to finish before switching projects."));
			return;
		}

		resetConversationPane();
		setActiveSessionId(null);
		setContextMenu(null);
		setDeleteTargetId(null);
		setRunStatus("idle");
		setProjectFolder(folder);
		closeProjectMenu();
		// Marks "we're mid-flight waiting for a brand-new session for this
		// project" so the agentUpdate push handler can attribute config/
		// session/slashCommands updates that arrive before this RPC
		// resolves (see that handler's isOwnPendingUpdate comment) --
		// otherwise e.g. the model selector's config can arrive and be
		// silently dropped while activeSessionId is still null.
		pendingPromptProjectFolderRef.current = folder;
		const prepared = await electroview.rpc?.request.prepareAgentSession({ cwd: folder, approvalMode });
		// Recorded regardless of whether ACP preparation succeeded --
		// selection happened either way (see listRecentProjects RPC).
		void refreshRecentProjects();
		if (prepared?.prepared === false) {
			pendingPromptProjectFolderRef.current = undefined;
			updateTranscriptItems((current) => upsertErrorItem(current, prepared.reason ?? "Failed to prepare agent session."));
			setRunStatus("error");
			return;
		}
		if (prepared?.sessionId) {
			setActiveSessionId(prepared.sessionId);
			void refreshAgentSessions({ reportErrors: false });
		}
		void refreshComposerMenuData();
	}

	async function handleClearProject() {
		if (isRunning) {
			return;
		}
		if (!projectFolder) {
			closeProjectMenu();
			return;
		}

		const started = await electroview.rpc?.request.startNewAgentChat();
		if (started === false) {
			updateTranscriptItems((current) => upsertErrorItem(current, "Wait for the active agent turn to finish before leaving this project."));
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

	/** The actual ACP send; shared by an immediate send and a dequeued one. */
	async function dispatchPrompt(
		trimmedPrompt: string,
		promptAttachments: AttachmentItem[],
		planMode: boolean,
		options?: { sessionId?: string | null },
	) {
		setStopReason(null);
		planModeSendRef.current = planMode;
		if (planMode) {
			planTurnStartIndexRef.current = transcriptItemsRef.current.length;
		}
		setRunStatus("starting");
		pendingPromptProjectFolderRef.current = projectFolder;
		optimisticUserTextRef.current = trimmedPrompt;
		setLastSubmittedAttachmentCount(promptAttachments.length);
		updateTranscriptItems((current) =>
			upsertMessageItem(current, { id: `local-${Date.now()}`, role: "user", text: trimmedPrompt }),
		);
		void scrollToBottom();

		// options?.sessionId overrides the live state for the clear-context
		// path (handlePlanClearAndImplement): handleNewChat() enqueues
		// setActiveSessionId(null), but the state update hasn't committed
		// yet in the same tick, so reading activeSessionId directly would
		// still see the old session id.
		const resolvedSessionId = options !== undefined ? (options.sessionId ?? undefined) : (activeSessionId ?? undefined);

		const response = await electroview.rpc?.request.startAgentPrompt({
			prompt: trimmedPrompt,
			cwd: projectFolder,
			model: selectedModel || undefined,
			approvalMode,
			planMode,
			attachments: promptAttachments.map(({ type, path, name }) => ({ type, path, name })),
			// Continuing an already-selected session: this is what triggers
			// send-time session/load priming on the backend. Omitted for a
			// brand-new chat, which creates a fresh session instead.
			sessionId: resolvedSessionId,
		});
		if (!response?.accepted) {
			pendingPromptProjectFolderRef.current = undefined;
			optimisticUserTextRef.current = null;
			planModeSendRef.current = false;
			updateTranscriptItems((current) => upsertErrorItem(current, "The agent is already running or the prompt was empty."));
			// DESIGN.md/ARCHITECTURE.md: "If a queued prompt fails, the model
			// records an error row and continues to later queued prompts."
			dequeueNextPrompt();
			return;
		}
		if (response.sessionId) {
			setActiveSessionId(response.sessionId);
			void refreshAgentSessions();
		}
	}

	/** Pops and dispatches the next queued prompt, if any (see dispatchPrompt/handleSend). */
	function dequeueNextPrompt() {
		const next = queuedPromptsRef.current[0];
		if (!next) {
			return;
		}
		setQueuedPrompts((current) => current.slice(1));
		void dispatchPrompt(next.text, next.attachments, next.planMode);
	}

	async function handleSend() {
		const trimmedPrompt = prompt.trim();
		if (!trimmedPrompt) {
			return;
		}

		// Sending again while the active session is running queues an
		// immutable snapshot rather than being rejected outright (see
		// QueuedPrompt/dequeueNextPrompt).
		if (isRunning) {
			setQueuedPrompts((current) => [...current, { id: `queued-${Date.now()}-${current.length}`, text: trimmedPrompt, attachments, planMode: isPlanModeEnabled }]);
			setPrompt("");
			setAttachments([]);
			return;
		}

		setPrompt("");
		const promptAttachments = attachments;
		setAttachments([]);
		await dispatchPrompt(trimmedPrompt, promptAttachments, isPlanModeEnabled);
	}

	function removeQueuedPrompt(id: string) {
		setQueuedPrompts((current) => current.filter((item) => item.id !== id));
	}

	async function handleStop() {
		if (!isRunning || isStopping || !activeSessionId) {
			return;
		}
		// DESIGN.md "Prompt Composer": Stop "clears queued prompts for that
		// same session."
		setQueuedPrompts([]);
		const cancelled = await electroview.rpc?.request.cancelAgentPrompt({ sessionId: activeSessionId });
		if (!cancelled) {
			updateTranscriptItems((current) => upsertErrorItem(current, "Could not stop the active agent turn."));
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
			if (!pendingPermission) {
				throw new Error("No pending permission request.");
			}
			accepted =
				(await electroview.rpc?.request.respondToAgentPermission({
					requestId,
					optionId,
					sessionId: pendingPermission.sessionId,
				})) ?? false;
			if (!accepted) {
				failureMessage = "Could not respond to the permission request. The agent turn may be stuck; try starting a new chat.";
			}
		} catch (error) {
			failureMessage = error instanceof Error ? error.message : "Failed to respond to the permission request.";
		}

		// Always clear pendingPermission, whether this succeeded or failed:
		// ApprovalPrompt has no cancel affordance of its own, so leaving it set
		// on failure would permanently freeze the composer with no way out.
		setPendingPermission((current) => (current?.requestId === requestId ? null : current));
		if (failureMessage) {
			updateTranscriptItems((current) => upsertErrorItem(current, failureMessage));
		}
	}

	function handleDraftFeedback(text: string) {
		setPrompt(text);
	}

	function handlePlanImplement() {
		setIsPlanModeEnabled(false);
		setPendingPlanEscalation(null);
		void dispatchPrompt("Go ahead and implement the plan you just proposed.", [], false);
	}

	async function handlePlanClearAndImplement() {
		const planText = pendingPlanEscalation?.planText;
		if (!planText) {
			return;
		}
		const resetOk = await handleNewChat();
		if (!resetOk) {
			return;
		}
		setQueuedPrompts([]);
		setIsPlanModeEnabled(false);
		setPendingPlanEscalation(null);
		// handleNewChat() enqueues setActiveSessionId(null), but the state
		// (and its useEffect-synced ref) haven't committed yet in the same
		// tick. The agentUpdate handler's isOwnPendingUpdate gate reads
		// activeSessionIdRef.current, so we must sync the ref now — otherwise
		// the new chat's early push updates (status/session/config) would be
		// gated out by a stale ref that still holds the old session id.
		activeSessionIdRef.current = null;
		void dispatchPrompt(`Implement this plan:\n\n${planText}`, [], false, { sessionId: null });
	}

	function handlePlanReject(reason: string) {
		setPendingPlanEscalation(null);
		void dispatchPrompt(reason, [], true);
	}

	async function handleNewChat(): Promise<boolean> {
		if (isRunning) {
			return false;
		}
		const started = await electroview.rpc?.request.startNewAgentChat();
		if (started === false) {
			updateTranscriptItems((current) => upsertErrorItem(current, "Wait for the active agent turn to finish before starting a new chat."));
			return false;
		}
		resetConversationPane();
		setActiveSessionId(null);
		setContextMenu(null);
		setDeleteTargetId(null);
		setRunStatus("idle");
		return true;
	}

	/**
	 * Selecting an existing session is pure local retrieval: it paints that
	 * session's durably cached transcript synchronously via
	 * getSessionTranscript and never talks to the agent runtime. Server-side
	 * context is instead primed lazily, only once the user actually sends
	 * into this session (see AGENTS.md send-time priming notes).
	 */
	async function handleSelectSession(sessionId: string) {
		if (isRunning || sessionId === activeSessionId) {
			return;
		}
		resetConversationPane();
		setContextMenu(null);
		setActiveSessionId(sessionId);
		setRunStatus("idle");
		const loadedSession = sessions.find((session) => session.sessionId === sessionId);
		setProjectFolder(
			sessionProjectFoldersRef.current.get(sessionId) ?? sessionProjectFolder(loadedSession),
		);
		const cachedTranscript = await electroview.rpc?.request.getSessionTranscript({ sessionId });
		for (const update of cachedTranscript ?? []) {
			applyHydratedUpdate(update);
		}
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
		const response = await electroview.rpc?.request.deleteAgentSession({ sessionId: targetId });
		if (!response?.deleted) {
			setDeleteTargetId(null);
			updateTranscriptItems((current) => upsertErrorItem(current, response?.reason ?? "Failed to delete chat."));
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
			// Transparent (not bg-background): the window itself is
			// transparent with a real NSVisualEffectView vibrancy layer
			// behind it (see src/bun/macWindowEffects.ts), so the sidebar's
			// translucent bg-l5-surface can reveal genuine frosted glass
			// instead of blurring a flat opaque color. The workspace area
			// gets its own explicit opaque backdrop below so chat content
			// stays fully opaque.
			className="fixed inset-0 flex h-screen w-screen overflow-hidden bg-transparent text-foreground"
			onDoubleClick={() => electroview.rpc?.request.toggleMaximizeWindow()}
		>
			<div
				className="electrobun-webkit-app-region-drag fixed left-32 right-0 top-0 z-10"
				style={{ height: `${FRAME_TOP_BAR_HEIGHT}px` }}
				aria-hidden="true"
				onDoubleClick={(event) => {
					event.stopPropagation();
					void electroview.rpc?.request.toggleMaximizeWindow();
				}}
			/>
			<div aria-hidden="true" className="fixed inset-0 z-0 bg-l5-background" />
			<div
				aria-hidden="true"
				className={cn(
					"l5-frame-top-gradient pointer-events-none fixed inset-x-0 top-0 z-20 transition-opacity duration-slow ease-out",
					isTranscriptScrolled ? "opacity-100" : "opacity-0",
				)}
				style={{ height: `${FRAME_TOP_GRADIENT_HEIGHT}px` }}
			/>
			<div
				className={cn(
					"l5-liquid-pane l5-glass-rim fixed z-30 flex flex-col overflow-hidden text-l5-glass-text transition-[opacity,transform,width] duration-standard ease-out",
					isSidebarCollapsed
						? "pointer-events-none -translate-x-4 opacity-0"
						: "translate-x-0 opacity-100",
				)}
				style={{
					left: `${FRAME_INSET}px`,
					top: `${FRAME_INSET}px`,
					bottom: `${FRAME_INSET}px`,
					width: `${expandedSidebarWidth}px`,
					borderRadius: "26px",
				}}
				aria-label="Project sidebar"
				aria-hidden={isSidebarCollapsed}
				onDoubleClick={(event) => event.stopPropagation()}
			>
				{isSidebarCollapsed ? null : (
					<>
						<div
							className="electrobun-webkit-app-region-drag relative shrink-0 border-b border-white/10 bg-gradient-to-b from-white/12 to-transparent"
							style={{ height: `${SIDEBAR_TOP_BAR_HEIGHT}px` }}
							onDoubleClick={(event) => {
								event.stopPropagation();
								void electroview.rpc?.request.toggleMaximizeWindow();
							}}
						/>

						<div className="flex min-h-0 flex-1 flex-col px-4 pb-4 pt-0">
							<SidebarButton
								aria-label="New chat"
								title="New chat"
								disabled={isRunning}
								className="h-11 w-full justify-start gap-3 px-3 text-body font-semibold text-l5-glass-text hover:bg-l5-glass-control-hover disabled:cursor-not-allowed disabled:opacity-40"
								onClick={() => void handleNewChat()}
							>
								<ICONS.newChat className="size-4 shrink-0" strokeWidth={1.8} />
								<span className="truncate">New chat</span>
							</SidebarButton>

							<section className="mt-3 flex min-h-0 flex-1 flex-col" aria-label="All chats">
								{/* DESIGN.md "Don't": no decorative icons -- the header is a
								    plain group label. */}
								<div className="flex h-9 shrink-0 items-center px-3 text-caption font-semibold uppercase tracking-wide text-l5-glass-muted">
									All chats
								</div>
								{sessions.length === 0 ? (
									<div className="px-3 pt-2 text-left">
										<p className="text-body font-medium text-l5-glass-text">No chats yet</p>
										<p className="mt-1 text-caption leading-4 text-l5-glass-muted">
											Start with New chat above — conversations you send show up here.
										</p>
									</div>
								) : (
									<div className="app-scrollbar-transparent min-h-0 flex-1 overflow-y-auto pr-1">
										<div className="flex flex-col gap-2">
											{sessionGroups.map((group) => {
												const isExpanded = visibleSessionGroupKeys.has(group.key);
												return (
													<section key={group.key} aria-label={`${group.label} chats`}>
														<button
															type="button"
															aria-expanded={isExpanded}
															className="flex h-8 w-full items-center gap-2 rounded-medium px-2 text-left text-caption font-semibold text-l5-glass-muted hover:bg-l5-glass-control-hover hover:text-l5-glass-text"
															onClick={() => setRememberedExpandedGroups((current) => {
																const next = new Set(current);
																if (next.has(group.key)) next.delete(group.key);
																else next.add(group.key);
																return next;
															})}
														>
															<ICONS.chevronRight className={cn("size-3.5 transition-transform", isExpanded && "rotate-90")} strokeWidth={2} />
															<span className="min-w-0 flex-1 truncate">{group.label}</span>
															<span className="tabular-nums opacity-70">{group.sessions.length}</span>
														</button>
												{isExpanded ? (
													<div className="mt-1 flex flex-col gap-1">
														{group.sessions.map((session) => {
															const isActive = session.sessionId === activeSessionId;
															return (
																<SidebarButton
																	key={session.sessionId}
																	aria-label={`Open ${sessionTitle(session)}`}
																	title={sessionTitle(session)}
																	aria-disabled={isRunning}
																	className={cn(
																		"h-9 w-full justify-start gap-2 pl-7 pr-2 text-body font-medium",
																		isActive
																			? "bg-l5-selected-surface text-l5-glass-text"
																			: "text-l5-glass-muted hover:bg-l5-glass-control-hover hover:text-l5-glass-text",
																		isRunning ? "cursor-not-allowed opacity-60" : "",
																	)}
																	onClick={() => void handleSelectSession(session.sessionId)}
																	onContextMenu={(event) => handleSessionContextMenu(event, session.sessionId)}
																>
																	<ICONS.chat className={cn("size-4 shrink-0", isActive ? "text-l5-accent" : "")} strokeWidth={1.7} />
																	<span className="min-w-0 flex-1 truncate">{sessionTitle(session)}</span>
																	{isActive ? (
																		<SessionActivityIndicator
																			status={activeSessionStatus}
																			isAwaitingPermission={Boolean(pendingPermission)}
																		/>
																	) : null}
																</SidebarButton>
															);
														})}
													</div>
												) : null}
													</section>
												);
											})}
										</div>
									</div>
								)}
							</section>

							<div className="border-t border-white/12 pt-3">
								<SidebarButton
									aria-label="Settings"
									title="Settings"
									className="h-11 w-full justify-start gap-3 px-3 text-body font-semibold text-l5-glass-muted hover:bg-l5-glass-control-hover hover:text-l5-glass-text"
									onClick={() => setIsSettingsOpen(true)}
								>
									<ICONS.settings className="size-4 shrink-0" strokeWidth={1.8} />
									<span className="truncate">Settings</span>
								</SidebarButton>
							</div>
						</div>

						<div
							role="separator"
							aria-orientation="vertical"
							aria-label="Resize sidebar"
							className="electrobun-webkit-app-region-no-drag absolute inset-y-4 right-[-5px] w-3 cursor-col-resize"
							onPointerDown={handleResizePointerDown}
							onPointerMove={handleResizePointerMove}
						>
							<div className="mx-auto h-full w-px rounded-full bg-transparent transition-colors hover:bg-l5-glass-border" />
						</div>
					</>
				)}
			</div>

			<div
				className={cn(
					"l5-sidebar-toggle-shell electrobun-webkit-app-region-no-drag fixed z-50",
					"transition-[background-color,border-color,color,height,left,top,width] duration-standard ease-out",
					isSidebarCollapsed ? "l5-sidebar-toggle-shell-collapsed" : "l5-sidebar-toggle-shell-expanded",
				)}
				style={{
					left: `${sidebarToggleLeft}px`,
					top: `${sidebarToggleTop}px`,
					width: `${sidebarToggleSize}px`,
					height: `${sidebarToggleSize}px`,
				}}
				onDoubleClick={(event) => event.stopPropagation()}
			>
				<button
					type="button"
					aria-label={isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
					title={isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
					className={cn(
						"flex h-full w-full items-center justify-center rounded-full transition-[background-color,color] duration-standard focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35",
						isSidebarCollapsed ? "text-l5-topbar-control" : "text-l5-glass-text",
					)}
					onClick={() => setIsSidebarCollapsed((value) => !value)}
				>
					{isSidebarCollapsed ? (
						<ICONS.sidebarExpand className="size-6 shrink-0" strokeWidth={1.9} />
					) : (
						<ICONS.sidebarCollapse className="size-4 shrink-0" strokeWidth={1.9} />
					)}
				</button>
			</div>
			{isSidebarCollapsed ? (
				<div
					className="electrobun-webkit-app-region-drag pointer-events-none fixed z-40 flex items-center"
					style={{
						left: `${sidebarToggleLeft + FRAME_TOP_CONTROL_SIZE + 12}px`,
						right: `${isReviewEligible ? 120 : isDashboardEligible ? 72 : 24}px`,
						top: `${FRAME_TOP_CONTROL_TOP}px`,
						height: `${FRAME_TOP_CONTROL_SIZE}px`,
					}}
				>
					<span className="truncate text-body font-semibold text-foreground/85">{topBarTitle}</span>
				</div>
			) : null}

			{contextMenu && menuSession ? (
				<div
					className={cn("electrobun-webkit-app-region-no-drag fixed z-30 w-44 rounded-card p-1.5", adaptivePopoverClass)}
					style={{ left: contextMenu.x, top: contextMenu.y }}
					onDoubleClick={(event) => event.stopPropagation()}
					onPointerDown={(event) => event.stopPropagation()}
				>
					<button
						type="button"
						className="flex h-10 w-full items-center gap-2 rounded-medium px-3 text-left text-body font-semibold text-destructive transition-colors duration-quick hover:bg-destructive/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-destructive/45 disabled:cursor-not-allowed disabled:opacity-40"
						disabled={isRunning && contextMenu.sessionId === activeSessionId}
						onClick={() => openDeleteDialog(contextMenu.sessionId)}
					>
						<ICONS.delete className="size-4 shrink-0" strokeWidth={1.9} />
						<span>Delete Chat...</span>
					</button>
				</div>
			) : null}

			{isDashboardEligible ? (
				<div
					className="electrobun-webkit-app-region-no-drag fixed z-[60]"
					style={{
						top: `${FRAME_TOP_CONTROL_TOP}px`,
						right: isReviewEligible ? `${FRAME_INSET * 2 + FRAME_TOP_CONTROL_SIZE + FRAME_TOP_CONTROL_GAP}px` : `${FRAME_INSET * 2}px`,
					}}
					onDoubleClick={(event) => event.stopPropagation()}
				>
					<div className="relative">
						<TopBarGlassButton
							aria-label="Toggle dashboard"
							tooltip="Dashboard · ⇧⌘D"
							aria-pressed={isDashboardPinned}
							className={cn(
								"transition-[color,transform] duration-standard",
								isDashboardPinned ? "border-l5-accent/45 text-l5-accent" : "text-l5-glass-text",
							)}
							onClick={() => {
								const shouldOpen = !isDashboardPinned;
								setIsDashboardPinned(shouldOpen);
								if (shouldOpen) {
									setInspectorOpenedAt((current) => ({ ...current, dashboard: Date.now() }));
									void refreshProjectGitStatus(projectFolder);
								}
							}}
						>
							<ICONS.dashboard className="size-4" strokeWidth={1.9} />
						</TopBarGlassButton>

						{inspectorLayout.dashboard === "drawer" ? (
							<InspectorBackdrop label="Close dashboard drawer" onClose={() => setIsDashboardPinned(false)} />
						) : null}
						{inspectorLayout.dashboard !== "closed" ? (
							<section
								ref={dashboardDrawerRef}
								tabIndex={-1}
								aria-label="Session dashboard"
								className={cn(
									"fixed flex flex-col overflow-hidden rounded-panel border border-border bg-l5-elevated-surface p-4 text-foreground shadow-e2",
									inspectorLayout.dashboard === "drawer" ? "z-50 w-[min(92vw,24rem)]" : "z-20 w-[23rem]",
								)}
								style={{
									top: `${FRAME_TOP_BAR_HEIGHT + FRAME_INSET}px`,
									bottom: `${FRAME_INSET}px`,
									right: `${(inspectorLayout.dashboard === "panel" ? reviewReservedWidth : 0) + FRAME_INSET}px`,
								}}
								onPointerDown={(event) => event.stopPropagation()}
							>
								<div className="flex items-center gap-3">
									<div className="flex size-9 shrink-0 items-center justify-center rounded-medium bg-l5-selected-surface text-l5-accent">
										<ICONS.dashboard className="size-5" strokeWidth={1.8} />
									</div>
									<div className="min-w-0 flex-1">
										<div className="truncate text-body font-semibold">Dashboard</div>
										<div className="truncate text-caption font-medium text-muted-foreground">{topBarTitle}</div>
									</div>
									<IconButton
										label="Refresh dashboard"
										className="size-9 rounded-medium hover:bg-muted/70"
										disabled={isGitStatusRefreshing}
										onClick={() => void refreshProjectGitStatus(projectFolder)}
									>
										<ICONS.refresh className={cn("size-4", isGitStatusRefreshing ? "animate-spin" : "")} strokeWidth={1.8} />
									</IconButton>
									<IconButton label="Close dashboard" className="size-9 rounded-medium hover:bg-muted/70" onClick={() => setIsDashboardPinned(false)}>
										<ICONS.close className="size-4" strokeWidth={1.8} />
									</IconButton>
								</div>

								<div className="app-scrollbar-transparent mt-4 grid min-h-0 gap-2 overflow-y-auto">
									<DashboardRow label="Changes" value={gitStatusSummary(gitStatus)} />
									<DashboardRow
										label="Branch"
										value={gitBranchSummary(gitStatus)}
										icon={<ICONS.branch className="size-3.5" strokeWidth={1.8} />}
									/>
									<DashboardPlanSection items={planItems} />
									<DashboardRow
										label="Sources"
										value={attachmentSummary(attachments.length, lastSubmittedAttachmentCount)}
									/>
								</div>
							</section>
						) : null}
					</div>
				</div>
			) : null}

			{isReviewEligible ? (
				<div
					className="electrobun-webkit-app-region-no-drag fixed z-40"
					style={{
						top: `${FRAME_TOP_CONTROL_TOP}px`,
						right: `${FRAME_INSET * 2}px`,
					}}
					onDoubleClick={(event) => event.stopPropagation()}
				>
					<TopBarGlassButton
						aria-label="Toggle review"
						tooltip="Review · ⇧⌘R"
						aria-pressed={isReviewOpen}
						className={cn(
							"transition-[color,transform] duration-standard",
							isReviewOpen ? "border-l5-accent/45 text-l5-accent" : "text-l5-glass-text",
						)}
						onClick={() => {
							const opening = !isReviewOpen;
							if (opening) setInspectorOpenedAt((current) => ({ ...current, review: Date.now() }));
							setIsReviewOpen(opening);
						}}
					>
						<ICONS.review className="size-4" strokeWidth={1.9} />
					</TopBarGlassButton>
				</div>
			) : null}

			{isReviewVisible && projectFolder ? (
				<ReviewPane
					cwd={projectFolder}
					width={reviewPaneWidth}
					topInset={FRAME_TOP_BAR_HEIGHT + FRAME_INSET}
					presentation={inspectorLayout.review === "drawer" ? "drawer" : "panel"}
					onWidthChange={setReviewPaneWidth}
					onClose={() => setIsReviewOpen(false)}
				/>
			) : null}

			<main
				className="electrobun-webkit-app-region-no-drag flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden px-6 pb-6 pt-20 transition-[margin] duration-standard ease-out"
				style={{
					marginRight: `${dashboardReservedWidth + reviewReservedWidth}px`,
					paddingLeft: `${24 + workspaceContentLeftInset}px`,
				}}
				aria-label="Workspace"
			>
				<div className={cn("mx-auto flex min-h-0 w-full max-w-5xl flex-1 flex-col", hasConversation ? "" : "justify-center")}>
					<div className={cn("flex min-h-0 w-full flex-col", hasConversation ? "relative h-full" : "")}>
						{hasConversation ? (
							<>
								<div
									ref={transcriptScrollRef}
									className="app-scrollbar-transparent fixed bottom-0 right-0 top-0 overflow-y-auto overscroll-contain px-6 pt-24"
									style={{
										left: `${workspaceContentLeftInset}px`,
										right: `${dashboardReservedWidth + reviewReservedWidth}px`,
									}}
								>
									{/* DESIGN.md "Chat": spacing between messages is 20px (L5Spacing.x5). */}
									<div ref={transcriptContentRef} className="mx-auto flex w-full max-w-3xl flex-col gap-5">
									{segments.map((segment) => {
										if (segment.type === "item") {
											const item = segment.item;
											if (item.type === "message") {
												return <MessageBubble key={item.key} message={item.message} />;
											}
											return <ErrorCard key={item.key} message={item.message} />;
										}
										return (
											<WorkingSection
												key={segment.key}
												items={segment.items}
												isLastSegment={segment === segments[segments.length - 1]}
												isSessionRunning={isRunning}
											/>
										);
									})}
										{/* Reserves space for the composer overlay, which sits on top of this
										    scroll layer (see DESIGN.md §13). Lives inside the tracked content
										    (not a padding style on the scroll container) so useStickToBottom's
										    own resize observer reacts when the composer's height changes. */}
										<div aria-hidden="true" style={{ height: `${composerHeight + 32}px` }} />
									</div>
								</div>
								<AgentScrollIndicator
									scrollRef={transcriptScrollRef}
									contentRef={transcriptContentRef}
									left={workspaceContentLeftInset}
									right={dashboardReservedWidth + reviewReservedWidth}
								/>
							</>
						) : null}

						{(planItems && planItems.length > 0) || composerStatus ? (
							<div className="mx-auto mb-2 flex w-full max-w-3xl shrink-0 items-center justify-center gap-2">
								{composerStatus ? (
									<div className={cn(adaptiveChipClass, "px-3 py-1.5")}>
										{composerStatus}
									</div>
								) : null}
								{planItems && planItems.length > 0 ? (
									<div ref={planPopoverRef}>
										<PlanChip
											items={planItems}
											isOpen={isPlanPopoverOpen}
											onToggle={() => setIsPlanPopoverOpen((value) => !value)}
										/>
									</div>
								) : null}
							</div>
						) : null}

						{/* Empty-chat ready state (DESIGN.md "Empty States"): the blank
						    workspace is intentional; one quiet line anchors the composer
						    as the obvious next action. No hero layouts. */}
						{hasConversation ? null : (
							<div className="mx-auto mb-6 w-full max-w-3xl select-none">
								<h1 className="text-h2 font-semibold text-foreground">
									{projectFolder ? `Working in ${projectLabel(projectFolder)}` : "What should we build?"}
								</h1>
							</div>
						)}

						{/* DESIGN.md "Prompt Composer": queued prompts "render
						    compactly above the composer and can be removed
						    before they start", below the Plan N/M chip. */}
						{queuedPrompts.length > 0 ? (
							<div className="mx-auto mb-2 flex w-full max-w-3xl shrink-0 flex-col gap-1.5">
								{queuedPrompts.map((queued, index) => (
									<div
										key={queued.id}
										className={cn(adaptiveChipClass, "flex items-center gap-2 py-1.5 pl-3 pr-1.5")}
									>
										<ICONS.chat className="size-3.5 shrink-0" strokeWidth={1.8} />
										<span className="min-w-0 flex-1 truncate" title={queued.text}>
											{index + 1}. {queued.text}
										</span>
										<button
											type="button"
											aria-label="Remove queued prompt"
											className="flex size-5 shrink-0 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
											onClick={() => removeQueuedPrompt(queued.id)}
										>
											<ICONS.close className="size-3" strokeWidth={2} />
										</button>
									</div>
								))}
							</div>
						) : null}

						{/* Two rounded-corner cards, "stacked": the footer card
						    (rendered second, so it naturally paints on top of
						    the composer card where they overlap) has a negative
						    top margin pulling it up underneath the composer
						    card's bottom edge, with extra top padding so its own
						    content clears that overlapped region instead of
						    being hidden by it. */}
						<div
							ref={composerContainerRef}
							className={cn("mx-auto flex w-full max-w-3xl shrink-0 flex-col", hasConversation ? "relative z-10 mt-auto" : "")}
						>
						<div className="l5-glass-composer l5-glass-rim relative z-10 overflow-visible rounded-panel">
							{pendingPermission ? (
								<ApprovalPrompt request={pendingPermission} onRespond={handlePermission} onDraftFeedback={handleDraftFeedback} />
							) : pendingPlanEscalation ? (
								<PlanEscalationPrompt planText={pendingPlanEscalation.planText} onClearAndImplement={handlePlanClearAndImplement} onImplement={handlePlanImplement} onReject={handlePlanReject} />
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
										className="pointer-events-none absolute inset-0 overflow-hidden whitespace-pre-wrap break-words text-body font-medium leading-6 text-foreground"
									>
										{renderComposerPreview(prompt)}
									</div>
									<textarea
										ref={textareaRef}
										value={prompt}
										// Stays editable during an active turn: sending
										// again while running queues the prompt instead
										// of being rejected (see handleSend/DESIGN.md
										// "Prompt Composer"'s queued-prompts behavior).
										placeholder="Ask Level5"
										aria-label="Message the agent"
										className="relative block w-full resize-none bg-transparent text-body font-medium leading-6 text-transparent caret-l5-accent placeholder:text-muted-foreground/60 focus:outline-none"
										style={{ minHeight: COMPOSER_MIN_HEIGHT, maxHeight: COMPOSER_MAX_HEIGHT }}
										onChange={(event) => setPrompt(event.target.value)}
										onKeyDown={handleComposerKeyDown}
										onScroll={handleComposerScroll}
									/>
								</div>
							</div>

							<div className="flex items-center gap-3 px-5 pb-3 pt-1">
								<div ref={plusMenuRef} className="relative">
									<IconButton
										label="Add to prompt"
										aria-haspopup="menu"
										aria-expanded={isPlusMenuOpen}
										onClick={() => setIsPlusMenuOpen((value) => !value)}
									>
										<ICONS.add className="size-5" strokeWidth={1.9} />
									</IconButton>

									{isPlusMenuOpen ? (
										<div
											role="menu"
											aria-label="Add to prompt"
											className={cn(
												"electrobun-webkit-app-region-no-drag app-scrollbar-transparent absolute bottom-[calc(100%+8px)] left-0 z-30 max-h-[420px] w-[320px] overflow-y-auto rounded-panel p-2",
												adaptivePopoverClass,
											)}
											onDoubleClick={(event) => event.stopPropagation()}
											onPointerDown={(event) => event.stopPropagation()}
										>
											<div className="flex flex-col gap-1">
												<ComposerMenuItem
													icon={<ICONS.attach className="size-4" strokeWidth={1.8} />}
													label="Upload file"
													onClick={() => void handleUploadFile()}
												/>
												<ComposerMenuItem
													icon={<ICONS.folder className="size-4" strokeWidth={1.8} />}
													label="Upload folder"
													onClick={() => void handleUploadFolder()}
												/>
												<ComposerMenuItem
													icon={<ICONS.planMode className="size-4" strokeWidth={1.8} />}
													label="Plan mode"
													description={isPlanModeEnabled ? "On" : undefined}
													onClick={() => {
														setIsPlanModeEnabled((value) => !value);
														closePlusMenu();
													}}
												/>
											</div>

											<div className="mt-2 border-t border-border pt-2">
												<div className="px-2 pb-1 text-caption font-semibold text-muted-foreground">Slash commands</div>
												{slashCommands.length === 0 ? (
													<div className="rounded-medium px-2 py-2 text-caption font-medium leading-4 text-muted-foreground">
														The current agent hasn't published any commands.
													</div>
												) : (
													<div className="flex flex-col gap-1">
														{slashCommands.map((command) => (
															<ComposerMenuItem
																key={command.name}
																icon={<span className="font-mono text-mono">/</span>}
																label={command.name}
																description={command.description}
																onClick={() => handleSelectSlashCommand(command)}
															/>
														))}
													</div>
												)}
											</div>

											{skills.length > 0 ? (
												<div className="mt-2 border-t border-border pt-2">
													<div className="px-2 pb-1 text-caption font-semibold text-muted-foreground">Skills</div>
													<div className="flex flex-col gap-1">
														{skills.map((skill) => (
															<ComposerMenuItem
																key={skill.id}
																icon={<ICONS.agent className="size-4" strokeWidth={1.8} />}
																label={skill.name}
																description={skill.description}
																onClick={() => handleSelectSkill(skill)}
															/>
														))}
													</div>
												</div>
											) : null}
										</div>
									) : null}
								</div>
								{isPlanModeEnabled ? (
									<button
										type="button"
										aria-pressed="true"
										aria-label="Plan mode enabled — click to cancel"
										onClick={() => setIsPlanModeEnabled(false)}
										className={cn(
											"l5-adaptive-chip electrobun-webkit-app-region-no-drag flex shrink-0 items-center gap-1.5 rounded-chip border border-l5-accent/28 px-2.5 py-1.5 text-caption font-medium text-l5-accent transition-colors duration-quick",
										)}
									>
										<ICONS.planMode className="size-3.5" strokeWidth={1.9} />
										<span>Plan</span>
									</button>
								) : null}
								<div ref={approvalMenuRef} className="relative">
									<button
										type="button"
										aria-haspopup="menu"
										aria-expanded={isApprovalMenuOpen}
										aria-label="Approval mode"
										className={cn(
											"flex shrink-0 items-center gap-2 rounded-medium px-2 py-2 text-body font-semibold text-foreground transition-colors disabled:cursor-not-allowed disabled:opacity-40",
											adaptiveHoverClass,
										)}
										onClick={() => setIsApprovalMenuOpen((value) => !value)}
									>
										<currentApprovalOption.icon className="size-4 text-l5-accent" strokeWidth={1.8} />
										<span>{currentApprovalOption.label}</span>
										<ICONS.chevronDown className="size-4 text-muted-foreground" strokeWidth={1.8} />
									</button>

									{isApprovalMenuOpen ? (
										<div
											role="menu"
											aria-label="Approval mode"
											className={cn(
												"electrobun-webkit-app-region-no-drag absolute bottom-[calc(100%+8px)] left-0 z-30 w-[320px] rounded-panel p-3",
												adaptivePopoverClass,
											)}
											onDoubleClick={(event) => event.stopPropagation()}
											onPointerDown={(event) => event.stopPropagation()}
										>
											<div className="px-1 pb-2 text-caption font-semibold text-muted-foreground">
												How should agent actions be approved?
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
															className="flex w-full items-start gap-3 rounded-medium px-2 py-2.5 text-left transition-colors hover:bg-muted/70 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35"
														>
															<option.icon className="mt-0.5 size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
															<span className="min-w-0 flex-1">
																<span className="block text-body font-semibold text-foreground">{option.label}</span>
																<span className="mt-0.5 block text-caption leading-4 text-muted-foreground">
																	{option.description}
																</span>
															</span>
															{isSelected ? (
																<ICONS.checkmark className="mt-0.5 size-4 shrink-0 text-foreground" strokeWidth={2} />
															) : null}
														</button>
													);
												})}
											</div>
										</div>
									) : null}
								</div>

								<div className="min-w-0 flex-1" />

								{hasConversation ? <ContextUsageRing used={usage?.used ?? 0} size={usage?.size ?? 1} /> : null}

								{modelOptions.length > 0 ? (
									<SelectControl
										label={modelConfigOption?.name ?? "Model"}
										value={selectedModel}
										onChange={(value) => setModel(value)}
										options={modelOptions}
									/>
								) : null}
								<button
									type="button"
									aria-label={isRunning ? "Stop agent" : "Send message"}
									className={cn(
										"relative flex size-11 shrink-0 items-center justify-center rounded-full transition-[background-color,transform] duration-quick",
										"focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35 active:scale-95",
										isRunning || prompt.trim()
											? "bg-l5-accent text-l5-accent-foreground hover:bg-l5-accent/90"
											: "bg-muted text-muted-foreground",
									)}
									disabled={isRunning ? isStopping : !prompt.trim()}
									onClick={() => (isRunning ? void handleStop() : void handleSend())}
								>
									{isRunning ? (
										<>
											<ICONS.loading className="absolute size-8 animate-spin opacity-55" strokeWidth={1.8} />
											<ICONS.stop className="size-4 fill-current" strokeWidth={2} />
										</>
									) : (
										<ICONS.send className="size-5" strokeWidth={2} />
									)}
								</button>
							</div>
							</>
							)}
						</div>

						{/* No explicit z-index on the footer below (position: relative
						    alone doesn't create a stacking context): the composer
						    card's z-10 above already paints on top of it
						    (z-index: auto counts as 0 for stacking purposes),
						    without trapping the footer's own popovers (e.g.
						    "Choose project", z-30 below) inside a capped
						    sub-context that could never escape above it. */}
						{hasConversation ? null : (
							<footer className="relative -mt-9 flex items-center justify-between rounded-panel bg-l5-secondary-background/70 px-6 pb-3 pt-10 text-body font-medium text-muted-foreground backdrop-blur-xl">
								<div ref={projectMenuRef} className="relative flex min-w-0 items-center">
									<button
										type="button"
										aria-haspopup="dialog"
										aria-expanded={isProjectMenuOpen}
										aria-label={projectFolder ? `Choose project, current project ${projectLabel(projectFolder)}` : "Choose project"}
										disabled={isRunning}
										className={cn(
											"flex min-w-0 items-center gap-2 rounded-medium px-2 py-2 text-foreground transition-colors",
											adaptiveHoverClass,
											"focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35",
											isRunning ? "cursor-not-allowed opacity-40" : "",
										)}
										onClick={() => {
											if (isRunning) {
												return;
											}
											setIsProjectMenuOpen((value) => !value);
										}}
										title={projectFolder ?? "Choose project"}
									>
										<ICONS.folder className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
										<span className="max-w-48 truncate">{projectLabel(projectFolder)}</span>
									</button>
									{projectFolder && composerProjectBranch ? (
										<span
											className="flex min-w-0 shrink-0 items-center gap-1 truncate px-2 text-caption text-muted-foreground"
											title={`Branch: ${composerProjectBranch}`}
										>
											<ICONS.branch className="size-3.5 shrink-0" strokeWidth={1.8} />
											<span className="min-w-0 truncate">{composerProjectBranch}</span>
										</span>
									) : null}

									{isProjectMenuOpen ? (
										<div
											role="dialog"
											aria-label="Choose project"
											className={cn(
												"electrobun-webkit-app-region-no-drag absolute bottom-[calc(100%+8px)] left-0 z-30 w-[336px] rounded-panel p-3",
												adaptivePopoverClass,
											)}
											onDoubleClick={(event) => event.stopPropagation()}
											onPointerDown={(event) => event.stopPropagation()}
										>
											<label className="flex h-10 items-center gap-2 rounded-input px-2 text-muted-foreground">
												<ICONS.search className="size-4 shrink-0" strokeWidth={1.8} />
												<input
													ref={projectSearchRef}
													type="search"
													value={projectSearch}
													placeholder="Search projects"
													aria-label="Search projects"
													className="min-w-0 flex-1 bg-transparent text-body font-medium text-foreground placeholder:text-muted-foreground focus:outline-none"
													onChange={(event) => setProjectSearch(event.target.value)}
												/>
											</label>

											<div className="app-scrollbar-transparent mt-2 max-h-56 overflow-y-auto pr-1">
												{filteredProjects.length === 0 ? (
													<div className="rounded-medium px-2 py-2 text-body font-medium text-muted-foreground">
														No projects match — try a shorter name.
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
																		"flex h-10 w-full items-center gap-2 rounded-medium px-2 text-left text-body font-semibold transition-colors",
																		"focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35",
																		isSelected
																			? "bg-l5-selected-surface text-foreground"
																			: "text-foreground hover:bg-muted/70",
																	)}
																	onClick={() => void handleChooseProject(project.path)}
																>
																	<ICONS.folder className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
																	<span className="min-w-0 flex-1 truncate">{project.name}</span>
																</button>
															);
														})}
													</div>
												)}
											</div>

											<div className="mt-2 border-t border-border pt-2">
												<button
													type="button"
													className="flex h-10 w-full items-center gap-2 rounded-medium px-2 text-left text-body font-semibold text-foreground transition-colors hover:bg-muted/70 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35"
													onClick={() => void handleSelectFolder()}
												>
													<ICONS.add className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
													<span className="min-w-0 flex-1 truncate">New project</span>
												</button>
												<button
													type="button"
													className="mt-1 flex h-10 w-full items-center gap-2 rounded-medium px-2 text-left text-body font-semibold text-foreground transition-colors hover:bg-muted/70 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35"
													onClick={() => void handleClearProject()}
												>
													<ICONS.close className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
													<span className="min-w-0 flex-1 truncate">Don't work in a project</span>
												</button>
											</div>
										</div>
									) : null}
								</div>
								<div className="flex shrink-0 items-center gap-2 text-caption">
									<ICONS.statusDot className={cn("size-2 fill-current", statusDotClass(runStatus))} strokeWidth={0} />
									<span>{statusLabel(runStatus, stopReason)}</span>
								</div>
							</footer>
							)}
						</div>
					</div>
				</div>
			</main>

			{deleteTarget ? (
				<div
					className="electrobun-webkit-app-region-no-drag fixed inset-0 z-40 flex items-center justify-center bg-black/25 p-6 backdrop-blur-md"
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
						className={cn("w-full max-w-sm rounded-panel p-5", adaptiveDialogClass)}
					>
						<div className="flex items-start gap-3">
							<div className="flex size-10 shrink-0 items-center justify-center rounded-full bg-destructive/10 text-destructive">
								<ICONS.delete className="size-5" strokeWidth={1.9} />
							</div>
							<div className="min-w-0 flex-1">
								<h2 id="delete-chat-title" className="text-h3 font-semibold text-foreground">
									Delete chat?
								</h2>
								<p id="delete-chat-description" className="mt-1 text-body leading-5 text-muted-foreground">
									This will remove "{sessionTitle(deleteTarget)}" from your recent chats.
								</p>
							</div>
						</div>
						<div className="mt-6 flex justify-end gap-2">
							<button
								type="button"
								className="h-10 rounded-medium px-4 text-body font-semibold text-muted-foreground transition-colors duration-quick hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35"
								onClick={() => setDeleteTargetId(null)}
							>
								Cancel
							</button>
							<button
								type="button"
								className="h-10 rounded-medium bg-destructive px-4 text-body font-semibold text-l5-danger-foreground transition-colors duration-quick hover:bg-destructive/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-destructive/45 disabled:cursor-not-allowed disabled:opacity-40"
								disabled={isRunning && deleteTarget.sessionId === activeSessionId}
								onClick={() => void confirmDeleteSession()}
							>
								Delete
							</button>
						</div>
					</section>
				</div>
			) : null}
			{isSettingsOpen ? <SettingsDialog onClose={() => setIsSettingsOpen(false)} /> : null}
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
				"flex size-10 shrink-0 items-center justify-center rounded-medium text-muted-foreground transition-colors duration-quick hover:bg-muted/70 hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35 disabled:cursor-not-allowed disabled:opacity-40",
				className,
			)}
			{...props}
		>
			{children}
		</button>
	);
}

function DashboardRow({ label, value, icon }: { label: string; value: string; icon?: ReactNode }) {
	return (
		<div className="grid grid-cols-[88px_minmax(0,1fr)] items-center gap-3 rounded-medium bg-muted/55 px-3 py-2">
			<div className="text-caption font-semibold text-muted-foreground">{label}</div>
			<div className="flex min-w-0 items-center justify-end gap-1.5 text-right text-caption font-semibold text-foreground">
				{icon ? <span className="shrink-0 text-muted-foreground">{icon}</span> : null}
				<span className="min-w-0 truncate">{value}</span>
			</div>
		</div>
	);
}

function DashboardPlanSection({ items }: { items: AgentPlanItem[] | null }) {
	if (!items || items.length === 0) {
		return <DashboardRow label="Plan" value={planSummary(items)} />;
	}

	return (
		<section className="rounded-medium bg-muted/55 px-3 py-2.5">
			<div className="flex items-center justify-between gap-3">
				<div className="text-caption font-semibold text-muted-foreground">Plan</div>
				<div className="shrink-0 text-caption font-semibold text-muted-foreground">
					{items.filter((item) => item.status === "completed").length}/{items.length}
				</div>
			</div>
			<div className="mt-2 flex flex-col gap-1.5">
				{items.map((item, index) => (
					<div key={`${item.title}-${index}`} className="flex items-start gap-2 text-caption font-semibold leading-5 text-foreground">
						<ICONS.statusDot className={cn("mt-[7px] size-2 shrink-0 fill-current", statusDotClass(item.status ?? ""))} strokeWidth={0} />
						<span className="min-w-0 flex-1 break-words">{item.title}</span>
						{item.status ? (
							<span className="shrink-0 text-caption font-medium text-muted-foreground">{item.status}</span>
						) : null}
					</div>
				))}
			</div>
		</section>
	);
}

function AgentScrollIndicator({
	scrollRef,
	contentRef,
	left,
	right,
}: {
	scrollRef: RefObject<HTMLElement | null>;
	contentRef: RefObject<HTMLElement | null>;
	left: number;
	right: number;
}) {
	const [metrics, setMetrics] = useState({ isVisible: false, railHeight: AGENT_SCROLL_INDICATOR_MIN_RAIL_HEIGHT, thumbTop: 0, thumbHeight: 0 });

	useEffect(() => {
		const scrollElement = scrollRef.current;
		if (!scrollElement) {
			return;
		}
		const element = scrollElement;

		let frame = 0;
		function update() {
			frame = 0;
			const maxScroll = element.scrollHeight - element.clientHeight;
			if (maxScroll <= 8) {
				setMetrics((current) => (current.isVisible ? { ...current, isVisible: false } : current));
				return;
			}

			const railHeight = Math.round(
				Math.min(
					AGENT_SCROLL_INDICATOR_MAX_RAIL_HEIGHT,
					Math.max(AGENT_SCROLL_INDICATOR_MIN_RAIL_HEIGHT, element.clientHeight * 0.32),
				),
			);
			const viewportRatio = element.clientHeight / element.scrollHeight;
			const thumbHeight = Math.round(
				Math.max(AGENT_SCROLL_INDICATOR_MIN_THUMB_HEIGHT, Math.min(railHeight, railHeight * viewportRatio)),
			);
			const thumbTop = Math.round((element.scrollTop / maxScroll) * (railHeight - thumbHeight));
			setMetrics((current) => {
				const next = { isVisible: true, railHeight, thumbTop, thumbHeight };
				return current.isVisible === next.isVisible &&
					current.railHeight === next.railHeight &&
					current.thumbTop === next.thumbTop &&
					current.thumbHeight === next.thumbHeight
					? current
					: next;
			});
		}

		function scheduleUpdate() {
			if (frame) {
				return;
			}
			frame = window.requestAnimationFrame(update);
		}

		const resizeObserver = new ResizeObserver(scheduleUpdate);
		resizeObserver.observe(element);
		if (contentRef.current) {
			resizeObserver.observe(contentRef.current);
		}
		element.addEventListener("scroll", scheduleUpdate, { passive: true });
		window.addEventListener("resize", scheduleUpdate);
		update();

		return () => {
			if (frame) {
				window.cancelAnimationFrame(frame);
			}
			resizeObserver.disconnect();
			element.removeEventListener("scroll", scheduleUpdate);
			window.removeEventListener("resize", scheduleUpdate);
		};
	}, [contentRef, scrollRef]);

	if (!metrics.isVisible) {
		return null;
	}

	const dashCount = Math.max(18, Math.min(28, Math.round(metrics.railHeight / 8)));
	const activeStart = Math.floor((metrics.thumbTop / metrics.railHeight) * dashCount);
	const activeCount = Math.max(3, Math.ceil((metrics.thumbHeight / metrics.railHeight) * dashCount));
	const activeEnd = activeStart + activeCount;

	return (
		<div
			aria-hidden="true"
			className="pointer-events-none fixed top-1/2 z-20 -translate-y-1/2"
			style={{
				left: `${Math.max(0, left + AGENT_SCROLL_INDICATOR_LEFT_INSET)}px`,
				maxWidth: `calc(100vw - ${left + right}px)`,
			}}
		>
			<div className="flex w-5 flex-col items-center justify-between" style={{ height: `${metrics.railHeight}px` }}>
				{Array.from({ length: dashCount }).map((_, index) => {
					const isActive = index >= activeStart && index < activeEnd;
					return (
						<div
							key={index}
							className={cn(
								"h-[3px] w-3 rounded-full transition-[background-color,opacity] duration-quick",
								isActive ? "bg-foreground opacity-80" : "bg-muted-foreground opacity-35",
							)}
						/>
					);
				})}
			</div>
		</div>
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
			className="flex h-10 w-full items-center gap-2 rounded-medium px-2 text-left text-body font-semibold text-foreground transition-colors hover:bg-muted/70 disabled:cursor-not-allowed disabled:opacity-40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35"
		>
			<span className="flex size-6 shrink-0 items-center justify-center text-muted-foreground">{icon}</span>
			<span className="min-w-0 flex-1 truncate">{label}</span>
			{description ? (
				<span className="max-w-[45%] shrink-0 truncate text-caption font-normal text-muted-foreground">{description}</span>
			) : null}
		</button>
	);
}

function AttachmentChip({ attachment, onRemove }: { attachment: AttachmentItem; onRemove: (id: string) => void }) {
	const Icon = attachment.type === "directory" ? ICONS.folder : ICONS.attach;
	return (
		<span className="inline-flex max-w-full items-center gap-1.5 rounded-chip bg-muted/70 px-3 py-1.5 text-caption font-medium text-foreground">
			<Icon className="size-3.5 shrink-0 text-muted-foreground" strokeWidth={1.8} />
			<span className="max-w-48 truncate">{attachment.name}</span>
			<button
				type="button"
				aria-label={`Remove ${attachment.name}`}
				className="flex size-4 shrink-0 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
				onClick={() => onRemove(attachment.id)}
			>
				<ICONS.close className="size-3" strokeWidth={2} />
			</button>
		</span>
	);
}

function ContextUsageRing({ used, size }: { used: number; size: number }) {
	const ratio = size > 0 ? Math.min(Math.max(used / size, 0), 1) : 0;
	const radius = 6;
	const circumference = 2 * Math.PI * radius;
	const dashOffset = circumference * (1 - ratio);
	const usedPercent = Math.round(ratio * 100);
	const leftPercent = 100 - usedPercent;
	// Per docs/DESIGN.md: accent below 70%, warning from 70%, danger from 90%.
	const progressColorClass = ratio >= 0.9 ? "text-l5-danger" : ratio >= 0.7 ? "text-l5-warning" : "text-l5-accent";

	return (
		<div
			tabIndex={0}
			role="group"
			aria-label={`Context window: ${usedPercent}% used, ${leftPercent}% left`}
			className="group relative flex shrink-0 items-center justify-center p-1 focus:outline-none"
		>
			<svg viewBox="0 0 16 16" className="size-4 -rotate-90" aria-hidden="true">
				<circle cx="8" cy="8" r={radius} fill="none" strokeWidth="2" className="stroke-muted-foreground/25" />
				<circle
					cx="8"
					cy="8"
					r={radius}
					fill="none"
					strokeWidth="2"
					strokeLinecap="round"
					strokeDasharray={circumference}
					strokeDashoffset={dashOffset}
					className={cn("stroke-current transition-[stroke-dashoffset]", progressColorClass)}
				/>
			</svg>

			<div
				role="tooltip"
				className={cn(
					"pointer-events-none absolute bottom-[calc(100%+12px)] left-1/2 z-30 w-[196px] -translate-x-1/2 rounded-medium px-4 py-3 text-center opacity-0 transition-opacity duration-quick group-hover:opacity-100 group-focus:opacity-100",
					adaptivePopoverClass,
				)}
			>
				<div className="text-caption font-medium text-muted-foreground">Context window:</div>
				<div className="mt-1 text-body font-semibold text-foreground">
					{usedPercent}% used ({leftPercent}% left)
				</div>
			</div>
		</div>
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
	const selectedOption = options.find((option) => option.value === value) ?? options[0];

	return (
		<Select value={selectedOption?.value ?? value} onValueChange={onChange}>
			<SelectTrigger
				aria-label={label}
				className="h-auto border-transparent bg-transparent px-2 py-2 text-body font-semibold shadow-none hover:bg-muted/70"
			>
				{icon}
				<SelectValue>{selectedOption?.label ?? value}</SelectValue>
			</SelectTrigger>
			<SelectContent position="popper" align="end" className="min-w-[10rem]">
				<SelectGroup>
					{options.map((option) => (
						<SelectItem key={option.value} value={option.value}>
							{option.label}
						</SelectItem>
					))}
				</SelectGroup>
			</SelectContent>
		</Select>
	);
}

function MessageBubble({ message }: { message: ChatMessage }) {
	const isUser = message.role === "user";
	// DESIGN.md "Chat": agent replies are readable text blocks, not speech
	// bubbles; user messages carry a subtle tint only -- no shadows, no
	// decorative chrome on either.
	if (!isUser) {
		return <Markdown className="w-full text-body leading-6 text-foreground">{message.text}</Markdown>;
	}
	return (
		<div className="w-full border-l-2 border-l5-accent bg-l5-selected-surface px-4 py-3">
			<Markdown className="text-body leading-6 text-foreground">
				{message.text}
			</Markdown>
		</div>
	);
}

/**
 * Composer-adjacent "Plan N/M" chip with a checklist popover, per
 * DESIGN.md "Prompt Composer". Plan state never renders as a transcript
 * row -- this replaces the old inline PlanCard entirely.
 */
function PlanChip({
	items,
	isOpen,
	onToggle,
}: {
	items: AgentPlanItem[];
	isOpen: boolean;
	onToggle: () => void;
}) {
	const total = items.length;
	const completed = items.filter((item) => item.status === "completed").length;
	return (
		<div className="relative">
			<button
				type="button"
				aria-haspopup="dialog"
				aria-expanded={isOpen}
				aria-label={`Plan progress: ${completed} of ${total} steps complete`}
				onClick={onToggle}
				className={cn(
					"l5-adaptive-chip electrobun-webkit-app-region-no-drag flex items-center gap-2 rounded-chip border px-3 py-1.5 text-caption font-medium transition-colors duration-quick",
					isOpen ? "border-l5-accent/28 text-l5-accent" : "border-border text-muted-foreground",
				)}
			>
				<ICONS.plan className="size-3.5" strokeWidth={1.9} />
				<span>
					Plan {completed}/{total}
				</span>
			</button>

			{isOpen ? (
				<div
					role="dialog"
					aria-label="Plan checklist"
					className={cn(
						"absolute bottom-[calc(100%+8px)] left-1/2 z-30 w-72 -translate-x-1/2 rounded-card p-3",
						adaptivePopoverClass,
					)}
					onPointerDown={(event) => event.stopPropagation()}
				>
					<div className="flex flex-col gap-2">
						{items.map((item, index) => (
							<div key={`${item.title}-${index}`} className="flex items-center gap-3 text-body">
								<ICONS.statusDot className={cn("size-2 shrink-0 fill-current", statusDotClass(item.status ?? ""))} strokeWidth={0} />
								<span className="min-w-0 flex-1 truncate">{item.title}</span>
								{item.status ? (
									<span className="shrink-0 text-caption font-medium text-muted-foreground">{item.status}</span>
								) : null}
							</div>
						))}
					</div>
				</div>
			) : null}
		</div>
	);
}

const APPROVAL_DETAILS_PREVIEW_LENGTH = 220;

function approvalQuestion(request: AgentPermissionRequest): string {
	const title = request.toolCall?.title;
	return title ? `Do you want me to go ahead with "${title}"?` : "Do you want me to proceed?";
}

function ApprovalPrompt({
	request,
	onRespond,
	onDraftFeedback,
}: {
	request: AgentPermissionRequest;
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
			<div className="text-body font-semibold leading-6 text-foreground">{approvalQuestion(request)}</div>

			{visibleDetails ? (
				<div className="mt-3 rounded-medium bg-muted/70 p-3">
					<pre className="overflow-x-auto whitespace-pre-wrap break-words font-mono text-caption leading-5 text-muted-foreground">
						{visibleDetails}
					</pre>
					{isDetailsLong ? (
						<button
							type="button"
							className="mt-1 text-caption font-semibold text-muted-foreground hover:text-foreground hover:underline"
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
							"flex items-center gap-3 rounded-medium px-3 py-2.5 text-left text-body font-medium text-foreground transition-colors duration-quick focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35 disabled:cursor-not-allowed disabled:opacity-60",
							index === highlightedIndex ? "bg-muted/80" : "hover:bg-muted/50",
						)}
						onMouseEnter={() => setHighlightedIndex(index)}
						onClick={() => void submitOption(option.optionId)}
					>
						<span className="flex size-5 shrink-0 items-center justify-center rounded-full border border-border bg-l5-elevated-surface text-caption font-semibold text-muted-foreground">
							{index + 1}
						</span>
						<span className="min-w-0 flex-1 truncate">{option.name}</span>
					</button>
				))}
			</div>

			<div className="mt-2 border-t border-border pt-2">
				{isWritingFeedback ? (
					<div className="flex items-center gap-2 px-1">
						<ICONS.edit className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
						<input
							ref={feedbackInputRef}
							type="text"
							value={feedbackText}
							placeholder="Tell the agent what to do differently"
							aria-label="Tell the agent what to do differently"
							className="min-w-0 flex-1 bg-transparent text-body text-foreground placeholder:text-muted-foreground focus:outline-none"
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
							className="shrink-0 rounded-small px-2 py-1 text-caption font-semibold text-muted-foreground transition-colors hover:bg-muted/70 disabled:cursor-not-allowed disabled:opacity-60"
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
							className="shrink-0 rounded-small bg-l5-accent px-3 py-1.5 text-caption font-semibold text-l5-accent-foreground transition-colors hover:bg-l5-accent/90 disabled:cursor-not-allowed disabled:opacity-60"
							onClick={submitFeedback}
						>
							Submit
						</button>
					</div>
				) : (
					<button
						type="button"
						disabled={isSubmitting}
						className="flex items-center gap-2 rounded-medium px-3 py-2 text-left text-body font-medium text-muted-foreground transition-colors hover:bg-muted/50 disabled:cursor-not-allowed disabled:opacity-60"
						onClick={() => setIsWritingFeedback(true)}
					>
						<ICONS.edit className="size-4 shrink-0" strokeWidth={1.8} />
						<span>No, and tell the agent what to do differently</span>
					</button>
				)}
			</div>
		</div>
	);
}

function PlanEscalationPrompt({
	planText,
	onClearAndImplement,
	onImplement,
	onReject,
}: {
	planText: string;
	onClearAndImplement: () => void;
	onImplement: () => void;
	onReject: (reason: string) => void;
}) {
	const [isWritingReason, setIsWritingReason] = useState(false);
	const [reasonText, setReasonText] = useState("");
	const reasonInputRef = useRef<HTMLInputElement | null>(null);

	useEffect(() => {
		if (isWritingReason) {
			reasonInputRef.current?.focus();
		}
	}, [isWritingReason]);

	function submitReject() {
		if (!reasonText.trim()) {
			return;
		}
		onReject(reasonText.trim());
	}

	return (
		<div className="px-6 py-5">
			<div className="text-body font-semibold leading-6 text-foreground">Plan ready — how should the agent proceed?</div>
			<div className="app-scrollbar-transparent mt-3 max-h-[40vh] overflow-y-auto rounded-medium bg-muted/70 p-3">
				<Markdown className="text-caption leading-5 text-muted-foreground">{planText}</Markdown>
			</div>
			<div className="mt-4 flex flex-col gap-1">
				<button
					type="button"
					className="flex items-center gap-3 rounded-medium px-3 py-2.5 text-left text-body font-medium text-foreground transition-colors duration-quick hover:bg-muted/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35"
					onClick={onImplement}
				>
					<span className="flex size-5 shrink-0 items-center justify-center rounded-full border border-border bg-l5-elevated-surface text-caption font-semibold text-muted-foreground">1</span>
					<span className="min-w-0 flex-1 truncate">Start implementation</span>
				</button>
				<button
					type="button"
					className="flex items-center gap-3 rounded-medium px-3 py-2.5 text-left text-body font-medium text-foreground transition-colors duration-quick hover:bg-muted/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/35"
					onClick={onClearAndImplement}
				>
					<span className="flex size-5 shrink-0 items-center justify-center rounded-full border border-border bg-l5-elevated-surface text-caption font-semibold text-muted-foreground">2</span>
					<span className="min-w-0 flex-1 truncate">Clear context and start implementation</span>
				</button>
			</div>
			<div className="mt-2 border-t border-border pt-2">
				{isWritingReason ? (
					<div className="flex items-center gap-2 px-1">
						<ICONS.edit className="size-4 shrink-0 text-muted-foreground" strokeWidth={1.8} />
						<input
							ref={reasonInputRef}
							type="text"
							value={reasonText}
							placeholder="Tell the agent what to change"
							aria-label="Tell the agent what to change"
							className="min-w-0 flex-1 bg-transparent text-body text-foreground placeholder:text-muted-foreground focus:outline-none"
							onChange={(event) => setReasonText(event.target.value)}
							onKeyDown={(event) => {
								if (event.key === "Enter") {
									event.preventDefault();
									submitReject();
								} else if (event.key === "Escape") {
									event.preventDefault();
									setIsWritingReason(false);
									setReasonText("");
								}
							}}
						/>
						<button
							type="button"
							disabled={!reasonText.trim()}
							className="shrink-0 rounded-small bg-l5-accent px-3 py-1.5 text-caption font-semibold text-l5-accent-foreground transition-colors hover:bg-l5-accent/90 disabled:cursor-not-allowed disabled:opacity-60"
							onClick={submitReject}
						>
							Submit
						</button>
					</div>
				) : (
					<button
						type="button"
						className="flex items-center gap-2 rounded-medium px-3 py-2 text-left text-body font-medium text-muted-foreground transition-colors hover:bg-muted/50"
						onClick={() => setIsWritingReason(true)}
					>
						<ICONS.edit className="size-4 shrink-0" strokeWidth={1.8} />
						<span>No, and tell the agent what to change</span>
					</button>
				)}
			</div>
		</div>
	);
}

function ErrorCard({ message }: { message: string }) {
	return (
		<div className="flex w-full max-w-3xl items-start gap-3 rounded-card border border-destructive/20 bg-destructive/10 px-4 py-3 text-body font-medium text-destructive">
			<ICONS.error className="mt-1 size-4 shrink-0" strokeWidth={2} />
			<span className="min-w-0 flex-1">{message}</span>
		</div>
	);
}

export default App;
