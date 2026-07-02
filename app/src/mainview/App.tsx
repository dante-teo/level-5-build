import {
	type ButtonHTMLAttributes,
	type KeyboardEvent,
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
	MessageSquarePlus,
	PanelLeftClose,
	PanelLeftOpen,
	Plus,
	Send,
	Settings,
	ShieldCheck,
	SquareTerminal,
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

function App() {
	const [isSidebarCollapsed, setIsSidebarCollapsed] = useAtom(isSidebarCollapsedAtom);
	const [sidebarWidth, setSidebarWidth] = useAtom(sidebarWidthAtom);
	const [prompt, setPrompt] = useState("");
	const [projectFolder, setProjectFolder] = useState<string | null>(null);
	const [model, setModel] = useState<MockModelId>("mock-pro");
	const [approvalMode, setApprovalMode] = useState<ApprovalModeId>("ask");
	const [transcriptItems, setTranscriptItems] = useState<TranscriptItem[]>([]);
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

	useEffect(() => {
		const handler = (update: MockAgentUpdate) => {
			if (update.kind === "status") {
				setRunStatus(update.status);
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
			if (update.kind === "stop") {
				setStopReason(update.stopReason);
				setRunStatus("completed");
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
		await electroview.rpc?.request.resetMockChat();
		optimisticUserTextRef.current = null;
		setPrompt("");
		setTranscriptItems([]);
		currentPlanKeyRef.current = "plan-initial";
		setRunStatus("idle");
		setStopReason(null);
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
								className="h-11 w-full justify-start gap-3 px-3 text-[14px] font-medium text-foreground hover:bg-white/70"
								onClick={() => void handleNewChat()}
							>
								<MessageSquarePlus className="size-4 shrink-0" strokeWidth={1.8} />
								<span className="truncate">New chat</span>
							</SidebarButton>

							<div className="min-h-0 flex-1" />

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
					<div className={cn("flex min-h-0 w-full flex-col", hasConversation ? "h-full" : "")}>
						{hasConversation ? (
							<div className="min-h-0 flex-1 overflow-y-auto overscroll-contain pb-5 pr-1">
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

						<div className="mx-auto w-full max-w-3xl shrink-0 overflow-hidden rounded-[24px] border border-[rgba(0,0,0,0.1)] bg-[rgba(255,255,255,0.72)] shadow-[0_24px_70px_rgba(17,24,39,0.13)] backdrop-blur-2xl">
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
