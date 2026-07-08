import { UnifiedDiffView } from "@/DiffView";
import { buildUnifiedDiff, countDiffLines } from "@/diffFormat";
import { ICONS } from "@/lib/icon-map";
import { useExpandable } from "@/lib/useExpandable";
import { cn } from "@/lib/utils";
import type { ToolCallView } from "@/App";

export type ToolSubItem =
	| { kind: "text"; text: string }
	| { kind: "diff"; path: string; oldText: string | null; newText: string }
	| { kind: "terminal"; terminalId: string };

export function parseToolContent(content: unknown[] | undefined): ToolSubItem[] {
	if (!content || content.length === 0) {
		return [];
	}
	return content
		.map((entry): ToolSubItem | null => {
			if (!entry || typeof entry !== "object") {
				return null;
			}
			const object = entry as Record<string, unknown>;
			if (object.type === "content") {
				const inner = object.content as Record<string, unknown> | undefined;
				return typeof inner?.text === "string" ? { kind: "text", text: inner.text } : null;
			}
			if (object.type === "terminal" && typeof object.terminalId === "string") {
				return { kind: "terminal", terminalId: object.terminalId };
			}
			if (object.type === "diff" && typeof object.path === "string" && typeof object.newText === "string") {
				return { kind: "diff", path: object.path, oldText: typeof object.oldText === "string" ? object.oldText : null, newText: object.newText };
			}
			return null;
		})
		.filter((item): item is ToolSubItem => item !== null);
}

export function hasSubItemContent(tool: ToolCallView): boolean {
	return parseToolContent(tool.content).length > 0;
}

function SubItemRow({ item }: { item: ToolSubItem }) {
	// sub-items start collapsed; no auto-expand signal applies at this depth
	const [isExpanded, toggleExpanded] = useExpandable(false);
	if (item.kind === "text") {
		return (
			<pre className="app-scrollbar-transparent overflow-x-auto whitespace-pre-wrap rounded-medium bg-muted/70 p-3 font-mono text-caption leading-5 text-muted-foreground">
				{item.text}
			</pre>
		);
	}
	if (item.kind === "terminal") {
		return <div className="text-caption text-muted-foreground">Terminal {item.terminalId}</div>;
	}
	const { added, removed } = countDiffLines(item.oldText, item.newText);
	return (
		<div className="rounded-card border border-border bg-l5-secondary-background">
			<button
				type="button"
				aria-expanded={isExpanded}
				onClick={toggleExpanded}
				className="flex w-full items-center gap-2 border-b border-border px-3 py-2 text-left"
			>
				<span className="min-w-0 flex-1 truncate font-mono text-mono text-foreground">{item.path}</span>
				{added > 0 ? <span className="shrink-0 text-caption font-medium text-l5-success">+{added}</span> : null}
				{removed > 0 ? <span className="shrink-0 text-caption font-medium text-l5-danger">-{removed}</span> : null}
				<ICONS.chevronDown
					className={cn("size-4 shrink-0 text-muted-foreground transition-transform duration-quick", isExpanded ? "rotate-180" : "")}
					strokeWidth={1.8}
				/>
			</button>
			{isExpanded ? (
				<div className="px-3 py-2">
					<UnifiedDiffView diff={buildUnifiedDiff(item.path, item.oldText, item.newText)} />
				</div>
			) : null}
		</div>
	);
}

export function ToolSubItems({ tool }: { tool: ToolCallView }) {
	const subItems = parseToolContent(tool.content);
	if (subItems.length === 0) {
		return null;
	}
	return (
		<div className="flex flex-col gap-1.5 pl-6">
			{subItems.map((item, index) => (
				<SubItemRow key={item.kind === "diff" ? item.path : `${item.kind}-${index}`} item={item} />
			))}
		</div>
	);
}
