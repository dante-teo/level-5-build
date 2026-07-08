import { parseUnifiedDiffLines } from "@/diffFormat";
import { cn } from "@/lib/utils";

export function DiffGutterNumber({ value }: { value: number | undefined }) {
	return (
		<span className="inline-block w-8 shrink-0 select-none text-right tabular-nums text-muted-foreground/60">
			{value ?? ""}
		</span>
	);
}

export function UnifiedDiffView({ diff }: { diff: string }) {
	const lines = parseUnifiedDiffLines(diff);
	return (
		<pre className="app-scrollbar-transparent overflow-x-auto font-mono text-mono leading-5 text-foreground">
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
