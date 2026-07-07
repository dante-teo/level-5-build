import { describe, expect, test } from "bun:test";
import { openDatabase } from "./database";
import { getSetting, setSetting } from "./settingsStore";

describe("settingsStore", () => {
	test("getSetting returns null for a key that was never set", () => {
		const db = openDatabase(":memory:");
		expect(getSetting(db, "acpProvider")).toBeNull();
		db.close();
	});

	test("setSetting then getSetting round-trips the exact value written", () => {
		const db = openDatabase(":memory:");
		setSetting(db, "acpProvider", "omp");
		expect(getSetting(db, "acpProvider")).toBe("omp");
		db.close();
	});

	test("setSetting called twice with the same key overwrites rather than duplicating", () => {
		const db = openDatabase(":memory:");
		setSetting(db, "acpProvider", "devin");
		setSetting(db, "acpProvider", "omp");
		expect(getSetting(db, "acpProvider")).toBe("omp");
		db.close();
	});
});
