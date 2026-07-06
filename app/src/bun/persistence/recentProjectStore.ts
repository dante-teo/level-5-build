import type { Database } from "bun:sqlite";
import { stat } from "node:fs/promises";
import { basename, resolve } from "node:path";

// Ports app/Sources/Level5Core/RecentProjectStore.swift to TypeScript. That
// file is the native source of truth for this module's behavior: the
// `recent_projects` schema, the normalize/upsert/evict-to-10 policy, and the
// directory-existence validation semantics all mirror it exactly. Unlike the
// native store (which keeps timestamps as `Date`/seconds-since-epoch), this
// module keeps timestamps as epoch-millisecond numbers throughout, which is
// the idiomatic convention already used by `sessionStore.ts`.

export type RecentProject = {
	path: string;
	displayName: string;
	createdAt: number;
	lastOpenedAt: number;
};

export type RecentProjectValidation = {
	path: string;
	exists: boolean;
};

const MAX_RECENT_PROJECTS = 10;

type RecentProjectRow = {
	path: string;
	displayName: string;
	createdAt: number;
	lastOpenedAt: number;
};

/** Resolves to an absolute path with any trailing slash stripped, mirroring `URL(fileURLWithPath:).standardizedFileURL.path`. */
export function normalizedPath(path: string): string {
	return resolve(path);
}

export function listRecentProjects(db: Database): RecentProject[] {
	return db
		.query(
			`SELECT path, displayName, createdAt, lastOpenedAt
			 FROM recent_projects
			 ORDER BY lastOpenedAt DESC`,
		)
		.all() as RecentProjectRow[];
}

/**
 * Upserts the given path as the most recently opened project, preserving
 * `createdAt` from any existing row, then evicts every row outside the 10
 * most-recently-opened, matching the native store's eviction policy.
 */
export function upsertSelectedFolder(db: Database, path: string, now: () => number = Date.now): RecentProject {
	const normalized = normalizedPath(path);
	const displayName = basename(normalized);
	const openedAt = now();

	const existing = db
		.query(`SELECT createdAt FROM recent_projects WHERE path = ?`)
		.get(normalized) as { createdAt: number } | null;
	const createdAt = existing?.createdAt ?? openedAt;

	db.query(
		`INSERT INTO recent_projects (path, displayName, createdAt, lastOpenedAt)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(path) DO UPDATE SET
			displayName = excluded.displayName,
			lastOpenedAt = excluded.lastOpenedAt`,
	).run(normalized, displayName, createdAt, openedAt);

	db.run(`
		DELETE FROM recent_projects
		WHERE path NOT IN (
			SELECT path
			FROM recent_projects
			ORDER BY lastOpenedAt DESC
			LIMIT ${MAX_RECENT_PROJECTS}
		)
	`);

	return { path: normalized, displayName, createdAt, lastOpenedAt: openedAt };
}

export function removeRecentProject(db: Database, path: string): void {
	db.query(`DELETE FROM recent_projects WHERE path = ?`).run(normalizedPath(path));
}

/** Checks that the normalized path exists and is a directory, following symlinks (matches `FileManager.fileExists(atPath:isDirectory:)`). */
export async function validateDirectoryExistence(path: string): Promise<RecentProjectValidation> {
	const normalized = normalizedPath(path);
	try {
		const stats = await stat(normalized);
		return { path: normalized, exists: stats.isDirectory() };
	} catch {
		return { path: normalized, exists: false };
	}
}

export function hasRecentProjectsTable(db: Database): boolean {
	const row = db
		.query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'recent_projects'`)
		.get() as { name: string } | null;
	return row !== null;
}
