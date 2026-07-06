import { describe, expect, test } from "bun:test";
import { parseUnifiedDiffLines } from "./diffFormat";

describe("parseUnifiedDiffLines", () => {
	test("tracks old/new line numbers across a hunk", () => {
		const diff = [
			"diff --git a/src/App.tsx b/src/App.tsx",
			"index 1111111..2222222 100644",
			"--- a/src/App.tsx",
			"+++ b/src/App.tsx",
			"@@ -10,3 +10,4 @@",
			" unchanged line",
			"-removed line",
			"+added line one",
			"+added line two",
			" trailing context",
		].join("\n");

		expect(parseUnifiedDiffLines(diff)).toEqual([
			{ kind: "meta", text: "diff --git a/src/App.tsx b/src/App.tsx" },
			{ kind: "meta", text: "index 1111111..2222222 100644" },
			{ kind: "meta", text: "--- a/src/App.tsx" },
			{ kind: "meta", text: "+++ b/src/App.tsx" },
			{ kind: "hunk", text: "@@ -10,3 +10,4 @@" },
			{ kind: "context", text: " unchanged line", oldLine: 10, newLine: 10 },
			{ kind: "remove", text: "-removed line", oldLine: 11 },
			{ kind: "add", text: "+added line one", newLine: 11 },
			{ kind: "add", text: "+added line two", newLine: 12 },
			{ kind: "context", text: " trailing context", oldLine: 12, newLine: 13 },
		]);
	});

	test("resets counters at each new hunk header", () => {
		const diff = ["@@ -1,1 +1,1 @@", "-a", "+b", "@@ -50,1 +51,1 @@", "-c", "+d"].join("\n");

		const lines = parseUnifiedDiffLines(diff);
		expect(lines).toEqual([
			{ kind: "hunk", text: "@@ -1,1 +1,1 @@" },
			{ kind: "remove", text: "-a", oldLine: 1 },
			{ kind: "add", text: "+b", newLine: 1 },
			{ kind: "hunk", text: "@@ -50,1 +51,1 @@" },
			{ kind: "remove", text: "-c", oldLine: 50 },
			{ kind: "add", text: "+d", newLine: 51 },
		]);
	});

	test("leaves line numbers undefined before any hunk header is seen", () => {
		expect(parseUnifiedDiffLines("some preamble line")).toEqual([
			{ kind: "context", text: "some preamble line", oldLine: undefined, newLine: undefined },
		]);
	});
});
