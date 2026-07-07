import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";

// Same path convention as the native app's Level5Database
// (app/Sources/Level5Core/Level5Database.swift), so both clients can share
// one durable local state root.
export function defaultDatabasePath(): string {
	return resolve(homedir(), ".level5build", "level5.sqlite");
}

// Named, ordered migrations mirroring SessionPersistenceStore.migrations on
// the native side, one per table. Every statement is idempotent
// (`IF NOT EXISTS`), so re-running this list on every process start is safe
// and needs no separate applied-migrations bookkeeping table.
const MIGRATIONS: ReadonlyArray<{ identifier: string; migrate: (db: Database) => void }> = [
	{
		identifier: "createSessions",
		migrate: (db) => {
			db.run(`
				CREATE TABLE IF NOT EXISTS sessions (
					sessionId TEXT PRIMARY KEY,
					projectKey TEXT NOT NULL,
					backend TEXT NOT NULL,
					title TEXT NOT NULL,
					detail TEXT NOT NULL,
					providerUpdatedAt REAL,
					observedAt REAL,
					createdAt REAL NOT NULL
				)
			`);
			db.run(`
				CREATE INDEX IF NOT EXISTS idx_sessions_projectKey_observedAt
				ON sessions (projectKey, observedAt)
			`);
		},
	},
	{
		identifier: "createSessionTranscriptItems",
		migrate: (db) => {
			db.run(`
				CREATE TABLE IF NOT EXISTS session_transcript_items (
					id INTEGER PRIMARY KEY AUTOINCREMENT,
					sessionId TEXT NOT NULL REFERENCES sessions (sessionId) ON DELETE CASCADE,
					itemId TEXT NOT NULL,
					kind TEXT NOT NULL,
					payloadVersion INTEGER NOT NULL,
					payload TEXT NOT NULL,
					UNIQUE (sessionId, itemId)
				)
			`);
		},
	},
	{
		identifier: "createSessionTranscriptState",
		migrate: (db) => {
			db.run(`
				CREATE TABLE IF NOT EXISTS session_transcript_state (
					sessionId TEXT PRIMARY KEY REFERENCES sessions (sessionId) ON DELETE CASCADE,
					planPayload TEXT,
					usagePayload TEXT,
					stopReasonsPayload TEXT,
					referencesPayload TEXT,
					payloadVersion INTEGER NOT NULL
				)
			`);
		},
	},
	{
		// Deliberately not a foreign key onto `sessions`: a hidden marker must
		// outlive the (already-deleted) cached session row it refers to,
		// since its entire purpose is remembering a deletion after the cache
		// row is gone.
		identifier: "createHiddenSessions",
		migrate: (db) => {
			db.run(`
				CREATE TABLE IF NOT EXISTS hidden_sessions (
					sessionId TEXT PRIMARY KEY,
					hiddenAt REAL NOT NULL
				)
			`);
		},
	},
	{
		// Mirrors RecentProjectStore.migrations in
		// app/Sources/Level5Core/RecentProjectStore.swift.
		identifier: "createRecentProjects",
		migrate: (db) => {
			db.run(`
				CREATE TABLE IF NOT EXISTS recent_projects (
					path TEXT PRIMARY KEY,
					displayName TEXT NOT NULL,
					createdAt REAL NOT NULL,
					lastOpenedAt REAL NOT NULL
				)
			`);
			db.run(`
				CREATE INDEX IF NOT EXISTS idx_recent_projects_lastOpenedAt
				ON recent_projects (lastOpenedAt)
			`);
		},
	},
	{
		identifier: "createSettings",
		migrate: (db) => {
			db.run(`
				CREATE TABLE IF NOT EXISTS settings (
					key TEXT PRIMARY KEY,
					value TEXT NOT NULL
				)
			`);
		},
	},
];

/**
 * Opens (creating if needed) the durable local SQLite database and applies
 * every migration. Pass `:memory:` in tests instead of a file path.
 */
export function openDatabase(path: string = defaultDatabasePath()): Database {
	if (path !== ":memory:") {
		mkdirSync(dirname(path), { recursive: true });
	}
	const db = new Database(path);
	db.exec("PRAGMA foreign_keys = ON;");
	for (const migration of MIGRATIONS) {
		migration.migrate(db);
	}
	return db;
}
