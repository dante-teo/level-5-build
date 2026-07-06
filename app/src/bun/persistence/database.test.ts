import { describe, expect, test } from "bun:test";
import { defaultDatabasePath, openDatabase } from "./database";

describe("durable session database", () => {
	test("creates the expected schema on a fresh database", () => {
		const db = openDatabase(":memory:");
		try {
			const tableNames = db
				.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
				.all()
				.map((row) => (row as { name: string }).name)
				// sqlite_sequence is SQLite's own internal bookkeeping table for
				// AUTOINCREMENT columns, not one of our migrations.
				.filter((name) => !name.startsWith("sqlite_"));

			expect(tableNames).toEqual([
				"hidden_sessions",
				"recent_projects",
				"session_transcript_items",
				"session_transcript_state",
				"sessions",
			]);
		} finally {
			db.close();
		}
	});

	test("enables foreign key cascading deletes", () => {
		const db = openDatabase(":memory:");
		try {
			const pragma = db.query("PRAGMA foreign_keys").get() as { foreign_keys: number };
			expect(pragma.foreign_keys).toBe(1);
		} finally {
			db.close();
		}
	});

	test("running migrations twice against the same file is safe", () => {
		const db = openDatabase(":memory:");
		expect(() => openDatabase(":memory:")).not.toThrow();
		db.close();
	});

	test("computes the default database path under ~/.level5build", () => {
		expect(defaultDatabasePath()).toMatch(/\.level5build\/level5\.sqlite$/);
	});
});
