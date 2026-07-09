import { describe, expect, test } from "bun:test";
import type { AgentSessionSummary } from "@shared/rpc";
import { expandedSessionGroupKeys, groupSessionsByProject, PROJECTLESS_GROUP_KEY } from "./sessionGroups";

function session(sessionId: string, cwd: string, updatedAt: string, isNoProject = false): AgentSessionSummary {
	return { sessionId, cwd, updatedAt, isNoProject, title: sessionId, messageCount: 1 };
}

describe("groupSessionsByProject", () => {
	test("orders projects by their newest chat and chats by recency", () => {
		const groups = groupSessionsByProject([
			session("old-a", "/work/alpha", "2026-01-01T00:00:00Z"),
			session("new-a", "/work/alpha", "2026-01-03T00:00:00Z"),
			session("beta", "/work/beta", "2026-01-02T00:00:00Z"),
		]);
		expect(groups.map((group) => group.label)).toEqual(["alpha", "beta"]);
		expect(groups[0]?.sessions.map((item) => item.sessionId)).toEqual(["new-a", "old-a"]);
	});

	test("places projectless chats in a dedicated group", () => {
		const groups = groupSessionsByProject([
			session("explicit", "/ignored", "2026-01-02T00:00:00Z", true),
			session("empty", "", "2026-01-01T00:00:00Z"),
		]);
		expect(groups).toHaveLength(1);
		expect(groups[0]?.key).toBe(PROJECTLESS_GROUP_KEY);
		expect(groups[0]?.sessions).toHaveLength(2);
	});

	test("always expands the active project in addition to remembered groups", () => {
		const groups = groupSessionsByProject([
			session("alpha", "/work/alpha", "2026-01-01T00:00:00Z"),
			session("beta", "/work/beta", "2026-01-02T00:00:00Z"),
		]);
		expect([...expandedSessionGroupKeys(groups, new Set(["/work/alpha"]), "/work/beta")]).toEqual([
			"/work/beta",
			"/work/alpha",
		]);
	});
});
