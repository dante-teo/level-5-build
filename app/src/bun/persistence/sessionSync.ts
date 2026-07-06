import { homedir } from "node:os";
import { resolveAgentCwd } from "../agent/runtime";
import type { AgentSessionSummary, AgentUpdate } from "../../shared/rpc";
import type { PersistedSessionRow, PersistedTranscriptItem, PersistedTranscriptState } from "./sessionStore";

// Encode/decode boundary between this app's AgentSessionSummary/AgentUpdate[]
// shapes and the durable, schema-native PersistedSessionRow/PersistedTranscriptItem
// rows -- the electrobun analog of Level5BuildApp.TranscriptPersistenceCoding.
// A project's cwd doubles as its projectKey, matching the native convention
// that "a project's key is its normalized cwd".

export function toPersistedSessionRow(
	session: AgentSessionSummary,
	backend: string,
	observedAtMs: number = Date.now(),
): PersistedSessionRow {
	const providerUpdatedAt = Date.parse(session.updatedAt);
	return {
		sessionId: session.sessionId,
		projectKey: session.cwd,
		backend,
		title: session.title,
		// No compact subtitle concept in this app yet; kept for schema parity with native.
		detail: "",
		providerUpdatedAt: Number.isFinite(providerUpdatedAt) ? providerUpdatedAt : null,
		observedAt: observedAtMs,
		createdAt: observedAtMs,
	};
}

/**
 * `messageCount` is not part of the durable schema (native does not persist
 * it either); callers should derive it from the session's hydrated
 * transcript item count.
 */
export function toSessionSummary(row: PersistedSessionRow, messageCount: number): AgentSessionSummary {
	const updatedAtMs = row.observedAt ?? row.providerUpdatedAt ?? row.createdAt;
	return {
		sessionId: row.sessionId,
		title: row.title,
		cwd: row.projectKey,
		isNoProject: resolveAgentCwd(row.projectKey) === homedir(),
		updatedAt: new Date(updatedAtMs).toISOString(),
		messageCount,
	};
}

export type TranscriptSnapshot = {
	items: PersistedTranscriptItem[];
	state: PersistedTranscriptState;
};

/**
 * Splits an in-memory transcript array into ordered items (messages, tools,
 * errors, info) plus the singleton plan/usage state, mirroring
 * SessionPersistenceStore's table split on the native side. Item identity is
 * the entry's position in `transcript`: safe because the in-memory array
 * (`upsertTranscriptUpdate`) only ever appends or mutates in place, never
 * reorders or removes, so a given logical entry keeps the same index (and
 * therefore the same durable itemId) across every snapshot.
 */
export function snapshotTranscriptForPersistence(transcript: AgentUpdate[]): TranscriptSnapshot {
	const items: PersistedTranscriptItem[] = [];
	let planPayload: string | null = null;
	let usagePayload: string | null = null;

	transcript.forEach((update, index) => {
		if (update.kind === "plan") {
			planPayload = JSON.stringify(update);
			return;
		}
		if (update.kind === "usage") {
			usagePayload = JSON.stringify(update);
			return;
		}
		items.push({
			itemId: String(index),
			kind: update.kind,
			payloadVersion: 1,
			payload: JSON.stringify(update),
		});
	});

	return { items, state: { payloadVersion: 1, planPayload, usagePayload } };
}

/**
 * Reconstructs a replayable `AgentUpdate[]` from durable rows. Exact
 * interleaving of the plan/usage entries relative to other items does not
 * matter: `replayTranscript` re-emits each entry through the same handlers
 * live updates use, and both the renderer and `upsertTranscriptUpdate` treat
 * plan/usage as "replace whatever's current" rather than positional state.
 */
export function hydrateTranscript(
	items: PersistedTranscriptItem[],
	state: PersistedTranscriptState | null,
): AgentUpdate[] {
	const hydrated: AgentUpdate[] = items.map((item) => JSON.parse(item.payload) as AgentUpdate);
	if (state?.planPayload) {
		hydrated.push(JSON.parse(state.planPayload) as AgentUpdate);
	}
	if (state?.usagePayload) {
		hydrated.push(JSON.parse(state.usagePayload) as AgentUpdate);
	}
	return hydrated;
}

export function countMessages(transcript: AgentUpdate[]): number {
	return transcript.filter((update) => update.kind === "message").length;
}
