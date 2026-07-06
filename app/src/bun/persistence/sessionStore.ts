import type { Database } from "bun:sqlite";

// Mirrors PersistedSessionRow/PersistedTranscriptItem/PersistedTranscriptState
// in app/Sources/Level5Core/SessionPersistenceStore.swift. Payloads are opaque
// strings (already-serialized JSON) so this module stays shape-agnostic about
// transcript internals, same as the native store.

export type PersistedSessionRow = {
	sessionId: string;
	projectKey: string;
	backend: string;
	title: string;
	detail: string;
	providerUpdatedAt: number | null;
	observedAt: number | null;
	createdAt: number;
};

export type PersistedTranscriptItem = {
	itemId: string;
	kind: string;
	payloadVersion: number;
	payload: string;
};

export type PersistedTranscriptState = {
	planPayload?: string | null;
	usagePayload?: string | null;
	stopReasonsPayload?: string | null;
	referencesPayload?: string | null;
	payloadVersion: number;
};

export type FetchedTranscriptState = {
	planPayload: string | null;
	usagePayload: string | null;
	stopReasonsPayload: string | null;
	referencesPayload: string | null;
	payloadVersion: number;
};

// MARK: - Sessions

/**
 * Every known session across every project, newest observed first. The
 * sidebar is a single global list independent of whichever project is
 * currently selected for the next new chat, so this is its only source of
 * session discovery.
 */
export function listAllSessionRows(db: Database): PersistedSessionRow[] {
	return db
		.query(
			`SELECT sessionId, projectKey, backend, title, detail, providerUpdatedAt, observedAt, createdAt
			 FROM sessions
			 ORDER BY observedAt DESC`,
		)
		.all() as PersistedSessionRow[];
}

export function upsertSessionRow(db: Database, row: PersistedSessionRow): void {
	db.query(
		`INSERT INTO sessions (sessionId, projectKey, backend, title, detail, providerUpdatedAt, observedAt, createdAt)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(sessionId) DO UPDATE SET
			projectKey = excluded.projectKey,
			backend = excluded.backend,
			title = excluded.title,
			detail = excluded.detail,
			providerUpdatedAt = excluded.providerUpdatedAt,
			observedAt = excluded.observedAt`,
	).run(
		row.sessionId,
		row.projectKey,
		row.backend,
		row.title,
		row.detail,
		row.providerUpdatedAt,
		row.observedAt,
		row.createdAt,
	);
}

/** Removes the session row and, via `ON DELETE CASCADE`, every transcript item and state row for it. */
export function deleteSession(db: Database, sessionId: string): void {
	db.query(`DELETE FROM sessions WHERE sessionId = ?`).run(sessionId);
}

// MARK: - Hidden sessions

/**
 * Records that the user deleted `sessionId` locally. Some ACP backends (real
 * Devin) don't implement `session/delete` at all, so the local session list
 * is not required to stay consistent with whatever the ACP server still
 * reports: once hidden, a session must never reappear, even across a
 * relaunch, regardless of whether the backend could also forget it.
 */
export function markSessionHidden(db: Database, sessionId: string, hiddenAt: number): void {
	db.query(
		`INSERT INTO hidden_sessions (sessionId, hiddenAt)
		 VALUES (?, ?)
		 ON CONFLICT(sessionId) DO UPDATE SET hiddenAt = excluded.hiddenAt`,
	).run(sessionId, hiddenAt);
}

export function hiddenSessionIds(db: Database): Set<string> {
	const rows = db.query(`SELECT sessionId FROM hidden_sessions`).all() as Array<{ sessionId: string }>;
	return new Set(rows.map((row) => row.sessionId));
}

// MARK: - Transcript items

export function upsertTranscriptItems(db: Database, sessionId: string, items: PersistedTranscriptItem[]): void {
	if (items.length === 0) return;
	const upsert = db.query(
		`INSERT INTO session_transcript_items (sessionId, itemId, kind, payloadVersion, payload)
		 VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(sessionId, itemId) DO UPDATE SET
			kind = excluded.kind,
			payloadVersion = excluded.payloadVersion,
			payload = excluded.payload`,
	);
	for (const item of items) {
		upsert.run(sessionId, item.itemId, item.kind, item.payloadVersion, item.payload);
	}
}

/** Ordered by first-insertion order; upserts preserve the original row, so no app-maintained sequence counter is needed. */
export function fetchTranscriptItems(db: Database, sessionId: string): PersistedTranscriptItem[] {
	return db
		.query(
			`SELECT itemId, kind, payloadVersion, payload
			 FROM session_transcript_items
			 WHERE sessionId = ?
			 ORDER BY id`,
		)
		.all(sessionId) as PersistedTranscriptItem[];
}

// MARK: - Transcript state

export function upsertTranscriptState(db: Database, sessionId: string, state: PersistedTranscriptState): void {
	db.query(
		`INSERT INTO session_transcript_state (sessionId, planPayload, usagePayload, stopReasonsPayload, referencesPayload, payloadVersion)
		 VALUES (?, ?, ?, ?, ?, ?)
		 ON CONFLICT(sessionId) DO UPDATE SET
			planPayload = excluded.planPayload,
			usagePayload = excluded.usagePayload,
			stopReasonsPayload = excluded.stopReasonsPayload,
			referencesPayload = excluded.referencesPayload,
			payloadVersion = excluded.payloadVersion`,
	).run(
		sessionId,
		state.planPayload ?? null,
		state.usagePayload ?? null,
		state.stopReasonsPayload ?? null,
		state.referencesPayload ?? null,
		state.payloadVersion,
	);
}

export function fetchTranscriptState(db: Database, sessionId: string): FetchedTranscriptState | null {
	const row = db
		.query(
			`SELECT planPayload, usagePayload, stopReasonsPayload, referencesPayload, payloadVersion
			 FROM session_transcript_state
			 WHERE sessionId = ?`,
		)
		.get(sessionId) as FetchedTranscriptState | null;
	return row ?? null;
}
