import { describe, expect, test } from "bun:test";
import { openDatabase } from "./database";
import {
	deleteSession,
	fetchTranscriptItems,
	fetchTranscriptState,
	hiddenSessionIds,
	listAllSessionRows,
	markSessionHidden,
	upsertSessionRow,
	upsertTranscriptItems,
	upsertTranscriptState,
} from "./sessionStore";

function testRow(overrides: Partial<Parameters<typeof upsertSessionRow>[1]> = {}) {
	return {
		sessionId: "session-1",
		projectKey: "/Users/dev/project",
		backend: "devin",
		title: "New chat",
		detail: "",
		providerUpdatedAt: null,
		observedAt: 1_000,
		createdAt: 1_000,
		...overrides,
	};
}

describe("SessionPersistenceStore", () => {
	test("listAllSessionRows returns nothing for an empty database", () => {
		const db = openDatabase(":memory:");
		expect(listAllSessionRows(db)).toEqual([]);
		db.close();
	});

	test("upsertSessionRow inserts a new row and listAllSessionRows returns it", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow());
		expect(listAllSessionRows(db)).toEqual([testRow()]);
		db.close();
	});

	test("upsertSessionRow updates an existing row rather than duplicating it", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow({ title: "New chat" }));
		upsertSessionRow(db, testRow({ title: "Renamed chat", observedAt: 2_000 }));
		const rows = listAllSessionRows(db);
		expect(rows).toHaveLength(1);
		expect(rows[0].title).toBe("Renamed chat");
		expect(rows[0].observedAt).toBe(2_000);
		db.close();
	});

	test("listAllSessionRows orders by observedAt descending, spanning every project", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow({ sessionId: "a", projectKey: "/one", observedAt: 1_000 }));
		upsertSessionRow(db, testRow({ sessionId: "b", projectKey: "/two", observedAt: 3_000 }));
		upsertSessionRow(db, testRow({ sessionId: "c", projectKey: "/one", observedAt: 2_000 }));
		expect(listAllSessionRows(db).map((row) => row.sessionId)).toEqual(["b", "c", "a"]);
		db.close();
	});

	test("deleteSession removes the session row", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow());
		deleteSession(db, "session-1");
		expect(listAllSessionRows(db)).toEqual([]);
		db.close();
	});

	test("deleteSession cascades to transcript items and transcript state", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow());
		upsertTranscriptItems(db, "session-1", [
			{ itemId: "item-1", kind: "message", payloadVersion: 1, payload: "{}" },
		]);
		upsertTranscriptState(db, "session-1", { payloadVersion: 1, planPayload: "{}" });

		deleteSession(db, "session-1");

		expect(fetchTranscriptItems(db, "session-1")).toEqual([]);
		expect(fetchTranscriptState(db, "session-1")).toBeNull();
		db.close();
	});

	test("markSessionHidden and hiddenSessionIds record local deletions independent of session rows", () => {
		const db = openDatabase(":memory:");
		markSessionHidden(db, "session-1", 5_000);
		expect(hiddenSessionIds(db)).toEqual(new Set(["session-1"]));
		db.close();
	});

	test("hidden markers survive deleting the session they refer to", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow());
		markSessionHidden(db, "session-1", 5_000);
		deleteSession(db, "session-1");
		expect(hiddenSessionIds(db)).toEqual(new Set(["session-1"]));
		db.close();
	});

	test("upsertTranscriptItems preserves first-insertion order across upserts", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow());
		upsertTranscriptItems(db, "session-1", [
			{ itemId: "item-1", kind: "message", payloadVersion: 1, payload: "first" },
			{ itemId: "item-2", kind: "message", payloadVersion: 1, payload: "second" },
		]);
		upsertTranscriptItems(db, "session-1", [
			{ itemId: "item-1", kind: "message", payloadVersion: 1, payload: "first-updated" },
			{ itemId: "item-3", kind: "tool", payloadVersion: 1, payload: "third" },
		]);

		const items = fetchTranscriptItems(db, "session-1");
		expect(items.map((item) => item.itemId)).toEqual(["item-1", "item-2", "item-3"]);
		expect(items[0].payload).toBe("first-updated");
		db.close();
	});

	test("upsertTranscriptState replaces the singleton state row for a session", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow());
		upsertTranscriptState(db, "session-1", { payloadVersion: 1, planPayload: "{\"items\":[]}" });
		upsertTranscriptState(db, "session-1", {
			payloadVersion: 2,
			planPayload: "{\"items\":[1]}",
			usagePayload: "{\"used\":1,\"size\":2}",
		});

		const state = fetchTranscriptState(db, "session-1");
		expect(state).toEqual({
			payloadVersion: 2,
			planPayload: "{\"items\":[1]}",
			usagePayload: "{\"used\":1,\"size\":2}",
			stopReasonsPayload: null,
			referencesPayload: null,
		});
		db.close();
	});

	test("fetchTranscriptState returns null when no state has been recorded", () => {
		const db = openDatabase(":memory:");
		upsertSessionRow(db, testRow());
		expect(fetchTranscriptState(db, "session-1")).toBeNull();
		db.close();
	});
});
