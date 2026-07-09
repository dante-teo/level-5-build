import { type PointerEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { InspectorBackdrop } from "@/components/InspectorBackdrop";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { UnifiedDiffView } from "@/DiffView";
import { electroview } from "@/lib/electrobun";
import { ICONS } from "@/lib/icon-map";
import { cn } from "@/lib/utils";
import { useDrawerFocusTrap } from "@/lib/useDrawerFocusTrap";
import type { ProjectChangedFile, ProjectFilePreview, ProjectReviewSnapshot } from "@shared/rpc";

export const REVIEW_PANE_DEFAULT_WIDTH = 600;
export const REVIEW_PANE_MIN_WIDTH = 420;
export const REVIEW_PANE_MAX_WIDTH = 820;

export function clampReviewPaneWidth(width: number): number {
	return Math.min(Math.max(width, REVIEW_PANE_MIN_WIDTH), REVIEW_PANE_MAX_WIDTH);
}

function folderName(path: string) {
	const segments = path.split("/").filter(Boolean);
	return segments[segments.length - 1] ?? path;
}

function statusBadgeFor(file: ProjectChangedFile): "Untracked" | "Mixed" | "Staged" | "Unstaged" | "Changed" {
	const hasStaged = file.indexStatus !== " " && file.indexStatus !== "?";
	const hasUnstaged = file.workingTreeStatus !== " " && file.workingTreeStatus !== "?";
	if (file.indexStatus === "?" && file.workingTreeStatus === "?") return "Untracked";
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
const LOADING_LINE_WIDTHS = ["w-3/4", "w-1/2", "w-2/3", "w-2/5"];
const EMPTY_REVIEW_FILES: ProjectChangedFile[] = [];

function formatBytes(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function ReviewErrorState({ message, rawOutput }: { message: string; rawOutput?: string }) {
	return (
		<div className="rounded-medium bg-muted/40 p-4 text-body text-muted-foreground">
			<div className="font-medium text-foreground">{message}</div>
			{rawOutput && rawOutput !== message ? (
				<details className="mt-2">
					<summary className="cursor-pointer text-caption">Details</summary>
					<pre className="mt-2 max-h-40 overflow-auto whitespace-pre-wrap text-caption">{rawOutput}</pre>
				</details>
			) : null}
		</div>
	);
}

function ReviewFilePreviewBody({ preview }: { preview: ProjectFilePreview | null }) {
	if (!preview) {
		return <div className="p-8 text-center text-caption text-muted-foreground">Diff unavailable.</div>;
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
				className="mx-auto max-h-[70vh] max-w-full object-contain"
			/>
		);
	}
	if (content.kind === "tooLarge") {
		return (
			<div className="p-8 text-center text-caption text-muted-foreground">
				This diff is too large to preview ({formatBytes(content.byteSize)} &gt; {formatBytes(content.limit)}).
			</div>
		);
	}
	if (content.kind === "metadata") {
		return <div className="p-8 text-center text-caption text-muted-foreground">{content.message}</div>;
	}
	return <ReviewErrorState message={content.error.message} rawOutput={content.error.rawOutput} />;
}

function ReviewPreview({ cwd, file }: { cwd: string; file: ProjectChangedFile }) {
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

	if (isLoading) {
		return (
			<div role="status" aria-label="Loading diff" className="flex animate-pulse flex-col gap-1 p-4">
				{LOADING_LINE_WIDTHS.map((lineWidth) => (
					<div key={lineWidth} className={cn("h-4 rounded-small bg-muted/50", lineWidth)} />
				))}
			</div>
		);
	}
	return <ReviewFilePreviewBody preview={preview} />;
}

function FileStats({ file }: { file: ProjectChangedFile }) {
	return (
		<span className="ml-auto flex shrink-0 gap-1 text-caption tabular-nums">
			{file.additions ? <span className="text-l5-success">+{file.additions}</span> : null}
			{file.deletions ? <span className="text-l5-danger">-{file.deletions}</span> : null}
		</span>
	);
}

function ReviewChangedFileSection({ cwd, file }: { cwd: string; file: ProjectChangedFile }) {
	const badge = statusBadgeFor(file);
	return (
		<section className="border-b border-border last:border-b-0">
			<div className="sticky top-0 z-10 flex items-center gap-2 border-b border-border bg-l5-background/95 px-3 py-2 backdrop-blur">
				<span className={cn("rounded-chip px-2 py-0.5 text-caption font-medium", STATUS_BADGE_CLASSES[badge])}>
					{badge}
				</span>
				<span className="min-w-0 flex-1 truncate font-mono text-mono">
					{file.oldPath ? `${file.oldPath} → ${file.path}` : file.path}
				</span>
				<FileStats file={file} />
			</div>
			<ReviewPreview cwd={cwd} file={file} />
		</section>
	);
}

function ReviewContent({
	snapshot,
	files,
	filteredFiles,
	cwd,
}: {
	snapshot: ProjectReviewSnapshot | null;
	files: ProjectChangedFile[];
	filteredFiles: ProjectChangedFile[];
	cwd: string;
}) {
	if (!snapshot) {
		return <div role="status" aria-label="Loading review" className="m-4 h-24 animate-pulse rounded-medium bg-muted/40" />;
	}
	if (!snapshot.isAvailable) {
		return (
			<div className="p-4">
				<ReviewErrorState message={snapshot.error.message} rawOutput={snapshot.error.rawOutput} />
			</div>
		);
	}
	if (filteredFiles.length === 0) {
		return (
			<div className="p-10 text-center">
				<div className="text-body font-medium">{files.length ? "No files match this filter" : "No changes yet"}</div>
				<div className="mt-1 text-caption text-muted-foreground">
					{files.length
						? "Clear the filter to see all changed files."
						: "Working-tree edits in this project will show up here."}
				</div>
			</div>
		);
	}
	return (
		<div className="flex min-h-0 flex-1 flex-col">
			<ScrollArea className="min-h-0 flex-1">
				{filteredFiles.map((file) => (
					<ReviewChangedFileSection
						key={file.oldPath ? `${file.oldPath}->${file.path}` : file.path}
						cwd={cwd}
						file={file}
					/>
				))}
			</ScrollArea>
			{snapshot.overflowCount > 0 ? (
				<div className="border-t border-border p-2 text-center text-caption text-muted-foreground">
					+{snapshot.overflowCount} more changed file{snapshot.overflowCount === 1 ? "" : "s"} not shown
				</div>
			) : null}
		</div>
	);
}

type ReviewPaneProps = {
	cwd: string;
	width: number;
	topInset: number;
	presentation?: "panel" | "drawer";
	onWidthChange: (width: number) => void;
	onClose: () => void;
};

export function ReviewPane({ cwd, width, topInset, presentation = "panel", onWidthChange, onClose }: ReviewPaneProps) {
	const [snapshot, setSnapshot] = useState<ProjectReviewSnapshot | null>(null);
	const [isLoading, setIsLoading] = useState(false);
	const [filter, setFilter] = useState("");
	const paneRef = useRef<HTMLElement | null>(null);
	const refreshRequestIdRef = useRef(0);

	const refresh = useCallback(async () => {
		const requestId = ++refreshRequestIdRef.current;
		setIsLoading(true);
		try {
			const result = await electroview.rpc?.request.getProjectReviewSnapshot({ cwd });
			if (requestId === refreshRequestIdRef.current) {
				setSnapshot(result ?? { isAvailable: false, error: { message: "Review is unavailable for this folder." } });
			}
		} catch (error) {
			if (requestId === refreshRequestIdRef.current) {
				setSnapshot({
					isAvailable: false,
					error: { message: error instanceof Error ? error.message : "Failed to load review." },
				});
			}
		} finally {
			if (requestId === refreshRequestIdRef.current) setIsLoading(false);
		}
	}, [cwd]);

	useEffect(() => {
		setSnapshot(null);
		void refresh();
	}, [refresh]);
	useDrawerFocusTrap(paneRef, presentation === "drawer", onClose);

	const files = snapshot?.isAvailable ? snapshot.files : EMPTY_REVIEW_FILES;
	const filteredFiles = useMemo(() => {
		const query = filter.trim().toLocaleLowerCase();
		return query
			? files.filter((file) => `${file.oldPath ?? ""} ${file.path}`.toLocaleLowerCase().includes(query))
			: files;
	}, [files, filter]);

	function handleResizePointerDown(event: PointerEvent<HTMLDivElement>) {
		event.preventDefault();
		event.currentTarget.setPointerCapture(event.pointerId);
	}
	function handleResizePointerMove(event: PointerEvent<HTMLDivElement>) {
		if (event.currentTarget.hasPointerCapture(event.pointerId)) {
			onWidthChange(clampReviewPaneWidth(window.innerWidth - event.clientX));
		}
	}

	const paneWidth = presentation === "drawer" ? "min(92vw, 680px)" : `${width}px`;
	return (
		<>
			{presentation === "drawer" ? <InspectorBackdrop label="Close review drawer" onClose={onClose} /> : null}
			<aside
				ref={paneRef}
				tabIndex={-1}
				aria-label="Review changed files"
				className={cn(
					"electrobun-webkit-app-region-no-drag fixed bottom-0 right-0 top-0 flex flex-col border-l border-border bg-l5-background outline-none",
					presentation === "drawer" ? "z-50 shadow-e3" : "z-20",
				)}
				style={{ width: paneWidth, paddingTop: `${topInset}px` }}
				onDoubleClick={(event) => event.stopPropagation()}
			>
				{presentation === "panel" ? (
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
				) : null}
				<header className="flex items-center gap-2 border-b border-border px-4 py-3">
					<div className="min-w-0 flex-1">
						<div className="truncate text-body font-semibold">Review</div>
						{snapshot?.isAvailable ? (
							<div className="truncate text-caption text-muted-foreground">
								{folderName(snapshot.root)}
								{snapshot.branch ? ` · ${snapshot.branch}` : ""}
							</div>
						) : null}
					</div>
					<Button
						variant="ghost"
						size="icon"
						className="size-8"
						aria-label="Refresh review"
						onClick={() => void refresh()}
					>
						<ICONS.refresh className={cn("size-4", isLoading && "animate-spin")} />
					</Button>
					<Button variant="ghost" size="icon" className="size-8" aria-label="Close review" onClick={onClose}>
						<ICONS.close className="size-4" />
					</Button>
				</header>
				{snapshot?.isAvailable ? (
					<div className="border-b border-border px-4 py-2">
						<input
							value={filter}
							onChange={(event) => setFilter(event.target.value)}
							placeholder="Filter changed files"
							className="w-full rounded-input border border-transparent bg-muted/40 px-3 py-1.5 text-body outline-none placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-l5-accent/35"
						/>
					</div>
				) : null}
				<ReviewContent snapshot={snapshot} files={files} filteredFiles={filteredFiles} cwd={cwd} />
			</aside>
		</>
	);
}
