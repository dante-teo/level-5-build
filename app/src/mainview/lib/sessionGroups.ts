import type { AgentSessionSummary } from "@shared/rpc";

export const PROJECTLESS_GROUP_KEY = "__projectless__";

export type SessionGroup = {
	key: string;
	label: string;
	cwd: string | null;
	newestAt: number;
	sessions: AgentSessionSummary[];
};

function timestamp(value: string): number {
	const parsed = Date.parse(value);
	return Number.isFinite(parsed) ? parsed : 0;
}

function projectName(cwd: string): string {
	const segments = cwd.split("/").filter(Boolean);
	return segments[segments.length - 1] ?? cwd;
}

function sessionGroupKey(session: AgentSessionSummary): string {
	return session.isNoProject || !session.cwd.trim() ? PROJECTLESS_GROUP_KEY : session.cwd;
}

export function groupSessionsByProject(sessions: AgentSessionSummary[]): SessionGroup[] {
	const grouped = new Map<string, AgentSessionSummary[]>();
	for (const session of sessions) {
		const key = sessionGroupKey(session);
		grouped.set(key, [...(grouped.get(key) ?? []), session]);
	}

	return [...grouped.entries()]
		.map(([key, groupSessions]) => {
			const orderedSessions = [...groupSessions].sort((left, right) => timestamp(right.updatedAt) - timestamp(left.updatedAt));
			const cwd = key === PROJECTLESS_GROUP_KEY ? null : key;
			return {
				key,
				cwd,
				label: cwd ? projectName(cwd) : "No project",
				newestAt: timestamp(orderedSessions[0]?.updatedAt ?? ""),
				sessions: orderedSessions,
			};
		})
		.sort((left, right) => right.newestAt - left.newestAt || left.label.localeCompare(right.label));
}

export function expandedSessionGroupKeys(
	groups: SessionGroup[],
	remembered: ReadonlySet<string>,
	activeCwd: string | null,
): Set<string> {
	const activeKey = activeCwd?.trim() ? activeCwd : PROJECTLESS_GROUP_KEY;
	return new Set(groups.filter((group) => group.key === activeKey || remembered.has(group.key)).map((group) => group.key));
}
