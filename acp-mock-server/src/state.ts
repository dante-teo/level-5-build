import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import type { MockState, SessionRecord } from "./types.js";

export function createEmptyState(): MockState {
	return {
		nextSession: 1,
		nextMessage: 1,
		nextTool: 1,
		nextTerminal: 1,
		sessions: {}
	};
}

export class StateStore {
	readonly path: string;
	private state: MockState;

	constructor(path: string) {
		this.path = resolve(path);
		this.state = this.load();
	}

	get snapshot(): MockState {
		return this.state;
	}

	nextId(kind: "session" | "message" | "tool" | "terminal"): string {
		const fixedIds = process.env.ACP_MOCK_FIXED_IDS === "1";
		if (fixedIds) {
			const value = {
				session: `sess_mock_${this.state.nextSession}`,
				message: `msg_mock_${this.state.nextMessage}`,
				tool: `call_mock_${this.state.nextTool}`,
				terminal: `term_mock_${this.state.nextTerminal}`
			}[kind];
			this.increment(kind);
			return value;
		}

		const random = crypto.randomUUID().replaceAll("-", "").slice(0, 12);
		const prefix = { session: "sess", message: "msg", tool: "call", terminal: "term" }[kind];
		this.increment(kind);
		return `${prefix}_${random}`;
	}

	saveSession(session: SessionRecord): void {
		this.state.sessions[session.sessionId] = session;
		this.save();
	}

	deleteSession(sessionId: string): void {
		const session = this.state.sessions[sessionId];
		if (session) {
			session.deleted = true;
			session.updatedAt = new Date().toISOString();
			this.save();
		}
	}

	private increment(kind: "session" | "message" | "tool" | "terminal"): void {
		if (kind === "session") this.state.nextSession += 1;
		if (kind === "message") this.state.nextMessage += 1;
		if (kind === "tool") this.state.nextTool += 1;
		if (kind === "terminal") this.state.nextTerminal += 1;
		this.save();
	}

	private load(): MockState {
		if (!existsSync(this.path)) {
			return createEmptyState();
		}
		try {
			const parsed = JSON.parse(readFileSync(this.path, "utf8")) as MockState;
			return {
				...createEmptyState(),
				...parsed,
				sessions: parsed.sessions ?? {}
			};
		} catch {
			return createEmptyState();
		}
	}

	private save(): void {
		mkdirSync(dirname(this.path), { recursive: true });
		writeFileSync(this.path, `${JSON.stringify(this.state, null, 2)}\n`);
	}
}
