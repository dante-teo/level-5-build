import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { openDatabase } from "./database";
import {
	hasRecentProjectsTable,
	listRecentProjects,
	normalizedPath,
	removeRecentProject,
	upsertSelectedFolder,
	validateDirectoryExistence,
} from "./recentProjectStore";

describe("RecentProjectStore", () => {
	test("hasRecentProjectsTable reports the migrated table", () => {
		const db = openDatabase(":memory:");
		expect(hasRecentProjectsTable(db)).toBe(true);
		db.close();
	});

	test("listRecentProjects returns nothing for an empty database", () => {
		const db = openDatabase(":memory:");
		expect(listRecentProjects(db)).toEqual([]);
		db.close();
	});

	test("upsertSelectedFolder inserts a row with a normalized path and derived displayName", () => {
		const db = openDatabase(":memory:");
		const project = upsertSelectedFolder(db, "/Users/dev/my-project/", () => 1_000);

		expect(project.path).toBe(resolve("/Users/dev/my-project"));
		expect(project.displayName).toBe("my-project");
		expect(project.createdAt).toBe(1_000);
		expect(project.lastOpenedAt).toBe(1_000);
		expect(listRecentProjects(db)).toEqual([project]);
		db.close();
	});

	test("re-upserting the same path preserves createdAt but bumps lastOpenedAt", () => {
		const db = openDatabase(":memory:");
		const first = upsertSelectedFolder(db, "/Users/dev/my-project", () => 1_000);
		const second = upsertSelectedFolder(db, "/Users/dev/my-project", () => 2_000);

		expect(second.createdAt).toBe(first.createdAt);
		expect(second.lastOpenedAt).toBe(2_000);

		const rows = listRecentProjects(db);
		expect(rows).toHaveLength(1);
		expect(rows[0]).toEqual(second);
		db.close();
	});

	test("upserting an 11th distinct path evicts the least-recently-opened one", () => {
		const db = openDatabase(":memory:");
		for (let i = 0; i < 10; i++) {
			upsertSelectedFolder(db, `/projects/project-${i}`, () => i * 1_000);
		}
		expect(listRecentProjects(db)).toHaveLength(10);

		upsertSelectedFolder(db, "/projects/project-10", () => 10_000);

		const rows = listRecentProjects(db);
		expect(rows).toHaveLength(10);
		const paths = rows.map((row) => row.path);
		expect(paths).not.toContain(resolve("/projects/project-0"));
		expect(paths).toContain(resolve("/projects/project-10"));
		db.close();
	});

	test("listRecentProjects orders newest-opened-first", () => {
		const db = openDatabase(":memory:");
		upsertSelectedFolder(db, "/projects/a", () => 1_000);
		upsertSelectedFolder(db, "/projects/b", () => 3_000);
		upsertSelectedFolder(db, "/projects/c", () => 2_000);

		expect(listRecentProjects(db).map((row) => row.displayName)).toEqual(["b", "c", "a"]);
		db.close();
	});

	test("removeRecentProject removes a row", () => {
		const db = openDatabase(":memory:");
		upsertSelectedFolder(db, "/projects/a", () => 1_000);
		removeRecentProject(db, "/projects/a");
		expect(listRecentProjects(db)).toEqual([]);
		db.close();
	});

	test("normalizedPath resolves to an absolute path without a trailing slash", () => {
		expect(normalizedPath("/projects/a/")).toBe(resolve("/projects/a"));
	});

	test("validateDirectoryExistence returns exists: true for a real directory", async () => {
		const dir = mkdtempSync(join(tmpdir(), "recent-project-store-"));
		const result = await validateDirectoryExistence(dir);
		expect(result).toEqual({ path: resolve(dir), exists: true });
	});

	test("validateDirectoryExistence returns exists: false for a nonexistent path", async () => {
		const missing = join(tmpdir(), "recent-project-store-does-not-exist", "nope");
		const result = await validateDirectoryExistence(missing);
		expect(result).toEqual({ path: resolve(missing), exists: false });
	});

	test("validateDirectoryExistence returns exists: false for a path that is a file", async () => {
		const dir = mkdtempSync(join(tmpdir(), "recent-project-store-"));
		const filePath = join(dir, "file.txt");
		writeFileSync(filePath, "hello");
		const result = await validateDirectoryExistence(filePath);
		expect(result).toEqual({ path: resolve(filePath), exists: false });
	});
});
