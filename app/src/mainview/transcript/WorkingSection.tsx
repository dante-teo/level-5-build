import { useEffect, useRef, useState } from "react";
import { hasSubItemContent, ToolSubItems } from "@/transcript/ToolSubItems";
import { ICONS, TOOL_KIND_ICONS } from "@/lib/icon-map";
import { useExpandable } from "@/lib/useExpandable";
import { cn } from "@/lib/utils";
import type { TranscriptItem, ToolCallView } from "@/App";

type WorkingItem = Extract<TranscriptItem, { type: "tool" | "thought" }>;

export function formatElapsed(ms: number): string {
	if (ms < 60_000) {
		return `${Math.round(ms / 1000)}s`;
	}
	return `${Math.floor(ms / 60_000)}m ${Math.round((ms % 60_000) / 1000)}s`;
}

type WorkingRow =
	| { type: "thought"; key: string; text: string }
	| { type: "toolGroup"; key: string; kind: string; tools: ToolCallView[] };

function groupWorkingItems(items: WorkingItem[]): WorkingRow[] {
	const rows: WorkingRow[] = [];
	for (const item of items) {
		if (item.type === "thought") {
			rows.push({ type: "thought", key: item.key, text: item.thought.text });
			continue;
		}
		const lastRow = rows[rows.length - 1];
		if (lastRow?.type === "toolGroup" && lastRow.kind === item.tool.kind) {
			lastRow.tools.push(item.tool);
		} else {
			rows.push({ type: "toolGroup", key: item.key, kind: item.tool.kind, tools: [item.tool] });
		}
	}
	return rows;
}

function ToolRow({ tool }: { tool: ToolCallView }) {
	const isInProgress = tool.status === "in_progress" || tool.status === "pending" || tool.status === "running";
	const isFailed = tool.status === "failed" || tool.status === "error";
	// DESIGN.md: tool rows auto-expand while in progress and remain expanded when failed
	const [isExpanded, toggleExpanded] = useExpandable(isInProgress || isFailed);
	const Icon = TOOL_KIND_ICONS[tool.kind] ?? ICONS.tool;
	return (
		<div className="flex flex-col gap-1.5">
			<button
				type="button"
				aria-expanded={isExpanded}
				disabled={!tool.text && !hasSubItemContent(tool)}
				onClick={toggleExpanded}
				className="flex w-full items-center gap-2 text-body text-muted-foreground transition-colors duration-quick hover:text-foreground disabled:hover:text-muted-foreground"
			>
				{isInProgress ? (
					<ICONS.loading className="size-4 shrink-0 animate-spin text-l5-accent" strokeWidth={1.8} />
				) : (
					<Icon className={cn("size-4 shrink-0", isFailed ? "text-l5-danger" : "")} strokeWidth={1.8} />
				)}
				<span className="min-w-0 flex-1 truncate text-left">{tool.title}</span>
				{isFailed ? <span className="shrink-0 text-caption font-medium text-l5-danger">Failed</span> : null}
			</button>
			{isExpanded ? <ToolSubItems tool={tool} /> : null}
		</div>
	);
}

const GROUP_LABELS: Record<string, (n: number) => string> = {
	read: (n) => `Read ${n} files`,
	edit: (n) => `Edited ${n} files`,
	delete: (n) => `Deleted ${n} files`,
	move: (n) => `Moved ${n} files`,
	search: (n) => `Ran ${n} searches`,
	execute: (n) => `Ran ${n} commands`,
	fetch: (n) => `Fetched ${n} resources`,
	switch_mode: (n) => `Switched mode ${n} times`,
	other: (n) => `${n} tool calls`,
	think: (n) => `${n} reasoning steps`,
};

function ToolGroupRow({ kind, tools }: { kind: string; tools: ToolCallView[] }) {
	const anyInProgress = tools.some((t) => t.status === "in_progress" || t.status === "pending" || t.status === "running");
	const anyFailed = tools.some((t) => t.status === "failed" || t.status === "error");
	const [isExpanded, toggleExpanded] = useExpandable(anyInProgress || anyFailed);
	const Icon = TOOL_KIND_ICONS[kind] ?? ICONS.tool;
	const label = (GROUP_LABELS[kind] ?? GROUP_LABELS.other)(tools.length);
	return (
		<div className="flex flex-col gap-1.5">
			<button
				type="button"
				aria-expanded={isExpanded}
				onClick={toggleExpanded}
				className="flex w-full items-center gap-2 text-body text-muted-foreground transition-colors duration-quick hover:text-foreground"
			>
				<Icon className="size-4 shrink-0" strokeWidth={1.8} />
				<span className="min-w-0 flex-1 truncate text-left">{label}</span>
				<ICONS.chevronDown className={cn("size-4 shrink-0 transition-transform duration-quick", isExpanded ? "rotate-180" : "")} strokeWidth={1.8} />
			</button>
			{isExpanded ? (
				<div className="flex flex-col gap-1 pl-6">
					{tools.map((tool) => (
						<ToolRow key={tool.toolCallId} tool={tool} />
					))}
				</div>
			) : null}
		</div>
	);
}

function ThoughtRow({ text }: { text: string }) {
	return <p className="text-body leading-6 text-muted-foreground">{text}</p>;
}

export function WorkingSection({
	items,
	isLastSegment,
	isSessionRunning,
}: {
	items: WorkingItem[];
	isLastSegment: boolean;
	isSessionRunning: boolean;
}) {
	const isActive = isLastSegment && isSessionRunning;
	const [isExpanded, toggleExpanded] = useExpandable(isActive);

	const [startTime] = useState(() => Date.now());
	const endTimeRef = useRef<number | null>(null);
	if (!isActive && endTimeRef.current === null) {
		endTimeRef.current = Date.now();
	}

	const [, forceTick] = useState(0);
	useEffect(() => {
		if (!isActive) {
			return;
		}
		const interval = setInterval(() => forceTick((tick) => tick + 1), 1000);
		return () => clearInterval(interval);
	}, [isActive]);

	const elapsedMs = (endTimeRef.current ?? Date.now()) - startTime;

	return (
		<div className="flex flex-col gap-2">
			<button
				type="button"
				aria-expanded={isExpanded}
				onClick={toggleExpanded}
				className="group flex w-full items-center gap-1.5 text-caption font-medium text-muted-foreground transition-colors duration-quick hover:text-foreground"
			>
				{isActive ? <ICONS.loading className="size-3.5 shrink-0 animate-spin text-l5-accent" strokeWidth={1.8} /> : null}
				<span>{isActive ? `Working for ${formatElapsed(elapsedMs)}` : `Worked for ${formatElapsed(elapsedMs)}`}</span>
				<ICONS.chevronRight className={cn("size-3.5 shrink-0 transition-transform duration-quick", isExpanded ? "rotate-90" : "")} strokeWidth={1.8} />
				{/* Hairline runs from the label to the right edge, fading out --
				    a quieter boundary than a full-width rule under the text. */}
				<span aria-hidden="true" className="ml-2 h-px min-w-0 flex-1 bg-gradient-to-r from-border to-transparent" />
			</button>
			{isExpanded ? (
				<div className="flex flex-col gap-3 border-l border-border/70 pl-4">
					{groupWorkingItems(items).map((row) =>
						row.type === "thought" ? (
							<ThoughtRow key={row.key} text={row.text} />
						) : row.tools.length > 1 ? (
							<ToolGroupRow key={row.key} kind={row.kind} tools={row.tools} />
						) : (
							<ToolRow key={row.tools[0].toolCallId} tool={row.tools[0]} />
						),
					)}
				</div>
			) : null}
		</div>
	);
}
