import { describe, expect, test } from "bun:test";
import type { AgentUpdate } from "../../shared/rpc";
import {
	countMessages,
	hydrateTranscript,
	snapshotTranscriptForPersistence,
	toPersistedSessionRow,
	toSessionSummary,
} from "./sessionSync";

describe("toPersistedSessionRow / toSessionSummary round trip", () => {
	test("round-trips a project-backed session", () => {
		const row = toPersistedSessionRow(
			{
				sessionId: "session-1",
				title: "Fix the bug",
				cwd: "/Users/dev/project",
				updatedAt: "2024-01-01T00:00:00.000Z",
				messageCount: 3,
			},
			"devin",
			1_700_000_000_000,
		);

		expect(row).toEqual({
			sessionId: "session-1",
			projectKey: "/Users/dev/project",
			backend: "devin",
			title: "Fix the bug",
			detail: "",
			providerUpdatedAt: Date.parse("2024-01-01T00:00:00.000Z"),
			observedAt: 1_700_000_000_000,
			createdAt: 1_700_000_000_000,
		});

		const summary = toSessionSummary(row, 5);
		expect(summary).toEqual({
			sessionId: "session-1",
			title: "Fix the bug",
			cwd: "/Users/dev/project",
			isNoProject: false,
			updatedAt: new Date(1_700_000_000_000).toISOString(),
			messageCount: 5,
		});
	});

	test("falls back to observedAt when the provider updatedAt cannot be parsed", () => {
		const row = toPersistedSessionRow(
			{ sessionId: "s", title: "New chat", cwd: "/tmp", updatedAt: "not-a-date", messageCount: 0 },
			"mock",
			42,
		);
		expect(row.providerUpdatedAt).toBeNull();
		expect(row.observedAt).toBe(42);
	});
});

describe("transcript snapshot / hydration", () => {
	test("splits plan and usage into singleton state, keeps everything else as items", () => {
		const transcript: AgentUpdate[] = [
			{ kind: "message", role: "user", messageId: "m1", content: { type: "text", text: "hi" } },
			{ kind: "plan", items: [{ title: "Step 1" }] },
			{ kind: "tool", tool: { toolCallId: "t1", title: "Read file", kind: "read", status: "completed" } },
			{ kind: "usage", used: 10, size: 100 },
		];

		const snapshot = snapshotTranscriptForPersistence(transcript);

		expect(snapshot.items.map((item) => item.itemId)).toEqual(["0", "2"]);
		expect(snapshot.items[0].kind).toBe("message");
		expect(snapshot.items[1].kind).toBe("tool");
		expect(snapshot.state.planPayload).toBe(JSON.stringify(transcript[1]));
		expect(snapshot.state.usagePayload).toBe(JSON.stringify(transcript[3]));
	});

	test("later plan/usage snapshots overwrite the singleton state rather than accumulating", () => {
		const first = snapshotTranscriptForPersistence([{ kind: "plan", items: [{ title: "Step 1" }] }]);
		expect(JSON.parse(first.state.planPayload ?? "null")).toEqual({ kind: "plan", items: [{ title: "Step 1" }] });

		const second = snapshotTranscriptForPersistence([
			{ kind: "plan", items: [{ title: "Step 1", status: "completed" }] },
		]);
		expect(JSON.parse(second.state.planPayload ?? "null")).toEqual({
			kind: "plan",
			items: [{ title: "Step 1", status: "completed" }],
		});
	});

	test("item identity stays stable across snapshots as the transcript grows in place", () => {
		const transcript: AgentUpdate[] = [
			{ kind: "message", role: "user", messageId: "m1", content: { type: "text", text: "hi" } },
		];
		const firstSnapshot = snapshotTranscriptForPersistence(transcript);
		expect(firstSnapshot.items.map((item) => item.itemId)).toEqual(["0"]);

		transcript.push({ kind: "message", role: "agent", messageId: "m2", content: { type: "text", text: "hello" } });
		const secondSnapshot = snapshotTranscriptForPersistence(transcript);
		expect(secondSnapshot.items.map((item) => item.itemId)).toEqual(["0", "1"]);
		expect(secondSnapshot.items[0].payload).toBe(firstSnapshot.items[0].payload);
	});

	test("hydrateTranscript reconstructs a replayable AgentUpdate array from items plus state", () => {
		const originalTranscript: AgentUpdate[] = [
			{ kind: "message", role: "user", messageId: "m1", content: { type: "text", text: "hi" } },
			{ kind: "plan", items: [{ title: "Step 1" }] },
			{ kind: "usage", used: 10, size: 100 },
		];
		const snapshot = snapshotTranscriptForPersistence(originalTranscript);

		const hydrated = hydrateTranscript(snapshot.items, snapshot.state);

		expect(hydrated).toContainEqual(originalTranscript[0]);
		expect(hydrated).toContainEqual(originalTranscript[1]);
		expect(hydrated).toContainEqual(originalTranscript[2]);
		expect(hydrated).toHaveLength(3);
	});

	test("hydrateTranscript tolerates a null state (no plan/usage recorded yet)", () => {
		const snapshot = snapshotTranscriptForPersistence([
			{ kind: "message", role: "user", messageId: "m1", content: { type: "text", text: "hi" } },
		]);
		expect(hydrateTranscript(snapshot.items, null)).toEqual([
			{ kind: "message", role: "user", messageId: "m1", content: { type: "text", text: "hi" } },
		]);
	});
});

describe("countMessages", () => {
	test("counts only message-kind entries", () => {
		const transcript: AgentUpdate[] = [
			{ kind: "message", role: "user", messageId: "m1", content: { type: "text", text: "hi" } },
			{ kind: "plan", items: [] },
			{ kind: "message", role: "agent", messageId: "m2", content: { type: "text", text: "hello" } },
			{ kind: "usage", used: 1, size: 2 },
		];
		expect(countMessages(transcript)).toBe(2);
	});
});
