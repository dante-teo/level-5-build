import { type PointerEvent, useEffect, useState } from "react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { parseUnifiedDiffLines } from "@/diffFormat";
import { electroview } from "@/lib/electrobun";
import { ICONS } from "@/lib/icon-map";
import { cn } from "@/lib/utils";
import type { ProjectChangedFile, ProjectFilePreview, ProjectReviewSnapshot } from "@shared/rpc";

// Net-new inspect-only Review column, ported from the native app's Review
// pane (see docs/DESIGN.md "Review Panel" / app/Sources/Level5Core/ProjectReview.swift).
// Never stages, discards, commits, reverts, or answers permissions.
//
// Diff/status semantics use the shared l5-success/l5-danger/l5-warning/
// l5-accent design tokens (see index.css), not a fixed dark editor palette,
// per DESIGN.md's Review Panel rule.

// DESIGN.md "Review Panel": "Width defaults to 600px and is user-resizable
// from 420px to 820px for the current open interaction only. Do not
// persist width or open state." -- kept as plain (non-atom) React state in
// the parent, so it resets every time the pane is mounted/closed-reopened.
export const REVIEW_PANE_DEFAULT_WIDTH = 600;
export const REVIEW_PANE_MIN_WIDTH = 420;
export const REVIEW_PANE_MAX_WIDTH = 820;

export function clampReviewPaneWidth(width: number): number {
	return Math.min(Math.max(width, REVIEW_PANE_MIN_WIDTH), REVIEW_PANE_MAX_WIDTH);
}

function folderName(path: string) {
	const parts = path.split("/").filter(Boolean);
	return parts.length > 0 ? parts[parts.length - 1] : path;
}

function statusBadgeFor(file: ProjectChangedFile): "Untracked" | "Mixed" | "Staged" | "Unstaged" | "Changed" {
	const hasStaged = file.indexStatus !== " " && file.indexStatus !== "?";
	const hasUnstaged = file.workingTreeStatus !== " " && file.workingTreeStatus !== "?";
	const isUntracked = file.indexStatus === "?" && file.workingTreeStatus === "?";
	if (isUntracked) return "Untracked";
	if (hasStaged && hasUnstaged) return "Mixed";
	if (hasStaged) return "Staged";
	if (hasUnstaged) return "Unstaged";
	return "Changed";
}

const STATUS_BADGE_CLASSES: Record<string, string> = {
	Untracked: "bg-l5-success/10 text-l5-success",
	Mixed: "bg-l5-warning/10 text-l5-warning",
	Staged: "bg-l5-selected-surface text-l5-accent",
	Unstaged: "bg-muted text-muted-foreground",
	Changed: "bg-muted text-muted-foreground",
};

function formatBytes(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function ReviewErrorState({ message, rawOutput }: { message: string; rawOutput?: string }) {
	return (
		<Alert>
			<AlertTitle>{message}</AlertTitle>
			{rawOutput && rawOutput !== message ? (
				<details className="mt-2">
					<summary className="cursor-pointer text-caption">Details</summary>
					<pre className="app-scrollbar-transparent mt-2 max-h-40 overflow-auto whitespace-pre-wrap text-caption">
						{rawOutput}
					</pre>
				</details>
			) : null}
			<AlertDescription className="sr-only">Review error</AlertDescription>
		</Alert>
	);
}

function DiffGutterNumber({ value }: { value: number | undefined }) {
	return <span className="inline-block w-8 shrink-0 select-none text-right text-muted-foreground/60">{value ?? ""}</span>;
}

function UnifiedDiffView({ diff }: { diff: string }) {
	const lines = parseUnifiedDiffLines(diff);
	return (
		<pre className="app-scrollbar-transparent overflow-x-auto rounded-medium bg-muted/40 p-3 font-mono text-mono leading-5 text-foreground">
			{lines.map((line, index) => (
				<div
					key={index}
					className={cn(
						"flex whitespace-pre px-1",
						line.kind === "add" ? "bg-l5-success/10 text-l5-success" : "",
						line.kind === "remove" ? "bg-l5-danger/10 text-l5-danger" : "",
						line.kind === "hunk" ? "font-semibold text-l5-accent" : "",
					)}
				>
					{line.kind === "meta" || line.kind === "hunk" ? null : (
						<span className="mr-2 flex shrink-0 gap-1 border-r border-border/60 pr-2">
							<DiffGutterNumber value={line.oldLine} />
							<DiffGutterNumber value={line.newLine} />
						</span>
					)}
					<span className="min-w-0 flex-1">{line.text.length > 0 ? line.text : "\u00A0"}</span>
				</div>
			))}
		</pre>
	);
}

function ReviewFilePreviewBody({ preview }: { preview: ProjectFilePreview | null }) {
	if (!preview) {
		return <div className="py-4 text-center text-caption text-muted-foreground">Diff unavailable.</div>;
	}
	const { content } = preview;
	if (content.kind === "unifiedDiff") {
		return <UnifiedDiffView diff={content.diff} />;
	}
	if (content.kind === "image") {
		return (
			<img
				src={`file://${content.path}`}
				alt={preview.file.path}
				className="max-h-96 max-w-full rounded-medium object-contain"
			/>
		);
	}
	if (content.kind === "tooLarge") {
		return (
			<div className="py-4 text-center text-caption text-muted-foreground">
				This diff is too large to preview ({formatBytes(content.byteSize)} &gt; {formatBytes(content.limit)}).
			</div>
		);
	}
	if (content.kind === "metadata") {
		return <div className="py-4 text-center text-caption text-muted-foreground">{content.message}</div>;
	}
	return <ReviewErrorState message={content.error.message} rawOutput={content.error.rawOutput} />;
}

function ReviewFileSection({ cwd, file }: { cwd: string; file: ProjectChangedFile }) {
	const [preview, setPreview] = useState<ProjectFilePreview | null>(null);
	const [isLoading, setIsLoading] = useState(true);

	useEffect(() => {
		let cancelled = false;
		setIsLoading(true);
		setPreview(null);
		electroview.rpc?.request
			.getFileDiffPreview({ cwd, file })
			.then((result) => {
				if (!cancelled) setPreview(result ?? null);
			})
			.catch((error: unknown) => {
				if (!cancelled) {
					setPreview({
						file,
						content: {
							kind: "error",
							error: { message: error instanceof Error ? error.message : "Diff could not be loaded." },
						},
					});
				}
			})
			.finally(() => {
				if (!cancelled) setIsLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [cwd, file]);

	const badge = statusBadgeFor(file);

	return (
		<Card className="bg-l5-secondary-background shadow-none">
			<div className="flex items-center gap-2 border-b border-border px-3 py-2">
				<Badge className={cn("shrink-0", STATUS_BADGE_CLASSES[badge])}>
					{badge}
				</Badge>
				<span className="min-w-0 flex-1 truncate font-mono text-mono text-foreground">
					{file.oldPath ? `${file.oldPath} \u2192 ${file.path}` : file.path}
				</span>
				{file.additions > 0 ? (
					<span className="shrink-0 text-caption font-medium text-l5-success">+{file.additions}</span>
				) : null}
				{file.deletions > 0 ? (
					<span className="shrink-0 text-caption font-medium text-l5-danger">-{file.deletions}</span>
				) : null}
			</div>
			<div className="px-3 py-2">
				{isLoading ? (
					<div className="py-4 text-center text-caption text-muted-foreground">Loading diff...</div>
				) : (
					<ReviewFilePreviewBody preview={preview} />
				)}
			</div>
		</Card>
	);
}

type ReviewPaneProps = {
	cwd: string;
	width: number;
	topInset: number;
	onWidthChange: (width: number) => void;
	onClose: () => void;
};

export function ReviewPane({ cwd, width, topInset, onWidthChange, onClose }: ReviewPaneProps) {
	const [snapshot, setSnapshot] = useState<ProjectReviewSnapshot | null>(null);
	const [isLoading, setIsLoading] = useState(false);
	const [filter, setFilter] = useState("");

	function handleResizePointerDown(event: PointerEvent<HTMLDivElement>) {
		event.preventDefault();
		event.currentTarget.setPointerCapture(event.pointerId);
	}

	function handleResizePointerMove(event: PointerEvent<HTMLDivElement>) {
		if (!event.currentTarget.hasPointerCapture(event.pointerId)) {
			return;
		}
		// The pane is anchored to the right edge of the window, so dragging
		// the handle left (smaller clientX) should widen it.
		onWidthChange(clampReviewPaneWidth(window.innerWidth - event.clientX));
	}

	async function refresh() {
		setIsLoading(true);
		try {
			const result = await electroview.rpc?.request.getProjectReviewSnapshot({ cwd });
			setSnapshot(result ?? { isAvailable: false, error: { message: "Review is unavailable for this folder." } });
		} catch (error) {
			setSnapshot({
				isAvailable: false,
				error: { message: error instanceof Error ? error.message : "Failed to load review." },
			});
		} finally {
			setIsLoading(false);
		}
	}

	useEffect(() => {
		setSnapshot(null);
		void refresh();
		// Re-fetch whenever the reviewed project changes. Opening/closing the
		// pane entirely is controlled by the parent unmounting/mounting it.
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [cwd]);

	const files = snapshot?.isAvailable ? snapshot.files : [];
	const trimmedFilter = filter.trim().toLowerCase();
	const filteredFiles = trimmedFilter ? files.filter((file) => file.path.toLowerCase().includes(trimmedFilter)) : files;

	return (
		<aside
			aria-label="Review changed files"
			className="l5-adaptive-surface electrobun-webkit-app-region-no-drag fixed bottom-0 right-0 top-0 z-20 flex flex-col border-l border-border"
			style={{ width: `${width}px`, paddingTop: `${topInset}px` }}
			onDoubleClick={(event) => event.stopPropagation()}
		>
			{/* DESIGN.md "Review Panel": user-resizable 420-820px, "keep a
			    visible drag target between the workspace and Review." */}
			<div
				role="separator"
				aria-orientation="vertical"
				aria-label="Resize review"
				aria-valuemin={REVIEW_PANE_MIN_WIDTH}
				aria-valuemax={REVIEW_PANE_MAX_WIDTH}
				aria-valuenow={width}
				className="absolute inset-y-0 left-[-4px] z-10 w-2 cursor-col-resize"
				onPointerDown={handleResizePointerDown}
				onPointerMove={handleResizePointerMove}
			>
				<div className="mx-auto h-full w-px bg-transparent transition-colors hover:bg-border" />
			</div>

			<header className="flex items-center gap-2 border-b border-border px-4 py-3">
				<div className="min-w-0 flex-1">
					<div className="truncate text-body font-semibold text-foreground">Review</div>
					{snapshot?.isAvailable ? (
						<div className="truncate text-caption font-medium text-muted-foreground">
							{folderName(snapshot.root)}
							{snapshot.branch ? ` \u00b7 ${snapshot.branch}` : ""}
						</div>
					) : null}
				</div>
				<Button
					type="button"
					aria-label="Refresh review"
					variant="ghost"
					size="icon-sm"
					onClick={() => void refresh()}
				>
					<ICONS.refresh className={cn("size-4", isLoading ? "animate-spin" : "")} strokeWidth={1.8} />
				</Button>
				<Button
					type="button"
					aria-label="Close review"
					variant="ghost"
					size="icon-sm"
					onClick={onClose}
				>
					<ICONS.close className="size-4" strokeWidth={1.8} />
				</Button>
			</header>

			{snapshot?.isAvailable ? (
				<div className="border-b border-border px-4 py-2">
					<Input
						value={filter}
						onChange={(event) => setFilter(event.target.value)}
						placeholder="Filter changed files"
						className="bg-transparent"
					/>
				</div>
			) : null}

			<div className="app-scrollbar-transparent flex-1 overflow-y-auto px-4 py-4">
				{!snapshot ? (
					<div className="py-10 text-center text-body text-muted-foreground">Loading review...</div>
				) : !snapshot.isAvailable ? (
					<ReviewErrorState message={snapshot.error.message} rawOutput={snapshot.error.rawOutput} />
				) : filteredFiles.length === 0 ? (
					<div className="py-10 text-center text-body text-muted-foreground">
						{files.length === 0 ? "No changes in this project." : "No files match this filter."}
					</div>
				) : (
					<div className="flex flex-col gap-4">
						{filteredFiles.map((file) => (
							<ReviewFileSection key={file.oldPath ? `${file.oldPath}->${file.path}` : file.path} cwd={cwd} file={file} />
						))}
						{snapshot.overflowCount > 0 ? (
							<div className="pt-2 text-center text-caption text-muted-foreground">
								+{snapshot.overflowCount} more changed file{snapshot.overflowCount === 1 ? "" : "s"} not shown
							</div>
						) : null}
					</div>
				)}
			</div>
		</aside>
	);
}
