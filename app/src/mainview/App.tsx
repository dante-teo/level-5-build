import type { ButtonHTMLAttributes, PointerEvent, ReactNode } from "react";
import { useAtom } from "jotai";
import { MessageSquarePlus, PanelLeftClose, PanelLeftOpen, Settings } from "lucide-react";
import appIcon from "@/assets/app-icon.png";
import { electroview } from "@/lib/electrobun";
import { cn } from "@/lib/utils";
import { isSidebarCollapsedAtom, sidebarWidthAtom } from "@/state/ui";

const SIDEBAR_MIN_WIDTH = 260;
const SIDEBAR_MAX_WIDTH = 420;
const SIDEBAR_COLLAPSED_WIDTH = 0;
const SIDEBAR_FLOATING_TOGGLE_GAP = 8;
const SIDEBAR_FLOATING_TOGGLE_TOP = 30;

type SidebarButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
	children: ReactNode;
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

function App() {
	const [isSidebarCollapsed, setIsSidebarCollapsed] = useAtom(isSidebarCollapsedAtom);
	const [sidebarWidth, setSidebarWidth] = useAtom(sidebarWidthAtom);
	const SidebarToggleIcon = isSidebarCollapsed ? PanelLeftOpen : PanelLeftClose;
	const renderedSidebarWidth = isSidebarCollapsed ? SIDEBAR_COLLAPSED_WIDTH : clampSidebarWidth(sidebarWidth);

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

			<main className="min-w-0 flex-1" aria-label="Workspace" />
		</div>
	);
}

export default App;
