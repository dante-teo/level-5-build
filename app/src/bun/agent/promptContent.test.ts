import { pathToFileURL } from "node:url";
import { describe, expect, test } from "bun:test";
import { PLAN_MODE_INSTRUCTION, buildPromptContent } from "./promptContent";

describe("buildPromptContent", () => {
	test("returns raw text block when planMode is false and no attachments", () => {
		const result = buildPromptContent("add a footer link", undefined, false);
		expect(result).toEqual([{ type: "text", text: "add a footer link" }]);
	});

	test("appends resource_link blocks for file and directory attachments", () => {
		const attachments = [
			{ type: "file" as const, path: "/tmp/readme.md", name: "readme.md" },
			{ type: "directory" as const, path: "/tmp/src", name: "src" },
		];
		const result = buildPromptContent("fix the build", attachments, false);
		expect(result).toEqual([
			{ type: "text", text: "fix the build" },
			{ type: "resource_link", uri: pathToFileURL("/tmp/readme.md").href, name: "readme.md" },
			{ type: "resource_link", uri: pathToFileURL("/tmp/src").href, name: "src", description: "Directory" },
		]);
	});

	test("prepends plan-mode instruction when planMode is true", () => {
		const attachments = [
			{ type: "file" as const, path: "/tmp/readme.md", name: "readme.md" },
			{ type: "directory" as const, path: "/tmp/src", name: "src" },
		];
		const withPlan = buildPromptContent("fix the build", attachments, true);
		const withoutPlan = buildPromptContent("fix the build", attachments, false);

		// Text block has instruction prepended
		expect(withPlan[0]).toEqual({ type: "text", text: PLAN_MODE_INSTRUCTION + "fix the build" });

		// Attachment blocks are identical
		expect(withPlan.slice(1)).toEqual(withoutPlan.slice(1));
	});

	test("percent-encodes special characters in attachment paths", () => {
		const attachments = [
			{ type: "file" as const, path: "/Users/John Smith/docs/report #1.md", name: "report #1.md" },
		];
		const result = buildPromptContent("review", attachments, false);
		const uri = (result[1] as Record<string, unknown>).uri as string;
		// pathToFileURL encodes spaces and # so the URI is valid
		expect(uri).not.toContain(" ");
		expect(uri).toContain("John%20Smith");
		expect(uri).toContain("%231");
		expect(uri).toBe(pathToFileURL("/Users/John Smith/docs/report #1.md").href);
	});
});
