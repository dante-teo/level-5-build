// Pure diff-formatting helpers, kept dependency-free (no @/lib/electrobun
// import chain) so they're testable under plain `bun test` -- ReviewPane.tsx
// (and anything importing it) pulls in the Electrobun webview bridge at
// module scope, which requires `window.__electrobun` and throws outside a
// real webview (see AGENTS.md's documented WKWebView limitation).

export type DiffLineKind = "meta" | "hunk" | "add" | "remove" | "context";

export type DiffLine = {
	kind: DiffLineKind;
	text: string;
	oldLine?: number;
	newLine?: number;
};

const HUNK_HEADER_PATTERN = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

// DESIGN.md "Diff Viewer": "Use a monospace font... old/new gutters."
// Parses old/new line numbers per unified-diff line so callers can render
// them as a leading gutter, mirroring a standard code-review diff.
export function parseUnifiedDiffLines(diff: string): DiffLine[] {
	let oldLine: number | undefined;
	let newLine: number | undefined;
	return diff.split("\n").map((text): DiffLine => {
		if (text.startsWith("diff --git") || text.startsWith("index ") || text.startsWith("--- ") || text.startsWith("+++ ")) {
			return { kind: "meta", text };
		}
		const hunkMatch = HUNK_HEADER_PATTERN.exec(text);
		if (hunkMatch) {
			oldLine = Number.parseInt(hunkMatch[1] ?? "0", 10);
			newLine = Number.parseInt(hunkMatch[3] ?? "0", 10);
			return { kind: "hunk", text };
		}
		if (text.startsWith("+")) {
			const line: DiffLine = { kind: "add", text, newLine };
			if (newLine !== undefined) newLine += 1;
			return line;
		}
		if (text.startsWith("-")) {
			const line: DiffLine = { kind: "remove", text, oldLine };
			if (oldLine !== undefined) oldLine += 1;
			return line;
		}
		const line: DiffLine = { kind: "context", text, oldLine, newLine };
		if (oldLine !== undefined) oldLine += 1;
		if (newLine !== undefined) newLine += 1;
		return line;
	});
}
