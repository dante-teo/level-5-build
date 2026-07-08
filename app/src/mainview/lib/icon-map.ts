import {
	AlertTriangle,
	ArrowRightLeft,
	Brain,
	Check,
	CheckCircle2,
	ChevronDown,
	ChevronRight,
	Circle,
	FileText,
	Folder,
	GitBranch,
	GitCommitHorizontal,
	GitPullRequest,
	Globe,
	Hand,
	Laptop,
	LayoutDashboard,
	Link,
	ListTodo,
	LoaderCircle,
	type LucideIcon,
	MessageSquare,
	MoreHorizontal,
	Move,
	Paperclip,
	PanelLeftClose,
	PanelLeftOpen,
	PanelRight,
	Pencil,
	Plus,
	RefreshCw,
	Search,
	Send,
	Settings,
	ShieldAlert,
	ShieldCheck,
	Sparkles,
	Square,
	SquarePen,
	SquareTerminal,
	Trash2,
	X,
} from "lucide-react";

/**
 * Centralized semantic icon names, mirroring app/Sources/Level5Design/L5Icon.swift's
 * centralization rule: app code should reference a semantic concept here rather than
 * importing lucide-react icons ad hoc. Where a concept maps to an L5Icon case, the
 * comment notes the native SF Symbol for traceability, but the Lucide icon chosen is
 * whichever reads most idiomatically for this concept rather than a literal 1:1 glyph
 * translation.
 */
export const ICONS = {
	// Shared with L5Icon
	agent: Sparkles, // L5Icon.agent (sparkles)
	awaitingPermission: Hand, // L5Icon.awaitingPermission (hand.raised.fill)
	branch: GitBranch, // L5Icon.branch (point.3.connected.trianglepath.dotted)
	chat: MessageSquare, // L5Icon.chat (bubble.left)
	close: X, // L5Icon.close (xmark)
	commit: GitCommitHorizontal, // L5Icon.commit (smallcircle.filled.circle)
	completed: CheckCircle2, // L5Icon.completed (checkmark.circle.fill)
	dashboard: LayoutDashboard, // L5Icon.dashboard (rectangle.3.group)
	error: AlertTriangle, // L5Icon.error (exclamationmark.triangle.fill)
	local: Laptop, // L5Icon.local (laptopcomputer)
	newChat: SquarePen, // L5Icon.newChat (square.and.pencil)
	pullRequest: GitPullRequest, // L5Icon.pullRequest (globe)
	refresh: RefreshCw, // L5Icon.refresh (arrow.clockwise)
	review: PanelRight, // L5Icon equivalent: inspect-only Review pane toggle
	running: LoaderCircle, // L5Icon.running (circle.dotted)
	settings: Settings, // L5Icon.settings (gearshape)
	sourceDocument: FileText, // L5Icon.sourceDocument (doc)
	sourceWeb: Link, // L5Icon.sourceWeb (link)
	workingTreeChanges: GitBranch, // L5Icon.workingTreeChanges (plus.rectangle) — not yet used in the electrobun UI

	// Electrobun-only concepts with no native L5Icon equivalent
	add: Plus,
	approvalAsk: Hand,
	approvalAuto: ShieldCheck,
	approvalFullAccess: ShieldAlert,
	attach: Paperclip,
	checkmark: Check,
	chevronDown: ChevronDown,
	chevronRight: ChevronRight,
	delete: Trash2,
	edit: Pencil,
	folder: Folder,
	info: ShieldCheck,
	loading: LoaderCircle,
	more: MoreHorizontal,
	plan: ListTodo,
	search: Search,
	send: Send,
	sidebarCollapse: PanelLeftClose,
	sidebarExpand: PanelLeftOpen,
	statusDot: Circle,
	stop: Square,
	tool: SquareTerminal,
} as const satisfies Record<string, LucideIcon>;

export type IconName = keyof typeof ICONS;

/**
 * Per-ToolKind icons for the transcript working section (see docs/DESIGN.md
 * "Chat"). Keys match ACP's ToolKind enum (schema.unstable.json); an
 * unrecognized/empty kind falls back to `ICONS.tool` at call sites.
 */
export const TOOL_KIND_ICONS: Record<string, LucideIcon> = {
	read: FileText,
	edit: ICONS.edit,
	delete: Trash2,
	move: Move,
	search: ICONS.search,
	execute: SquareTerminal,
	think: Brain,
	fetch: Globe,
	switch_mode: ArrowRightLeft,
	other: ICONS.tool,
};
