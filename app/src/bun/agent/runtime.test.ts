import { describe, expect, test } from "bun:test";
import {
	AGENT_CLIENT_CAPABILITIES,
	ACP_MOCK_SPAWN_FAILURE_MESSAGE,
	DEVIN_MISSING_CLI_MESSAGE,
	OMP_MISSING_CLI_MESSAGE,
	buildAgentSpawnOptions,
	buildMockSpawnOptions,
	buildSelectedPermissionResponse,
	buildDevinSpawnOptions,
	buildOmpSpawnOptions,
	devinPermissionMode,
	isAcpMockEnabled,
	isDevinAvailable,
	isOmpAvailable,
	normalizeAcpProvider,
	normalizeApprovalMode,
	pickAutoApproveOptionId,
	selectedAgentBackend,
	shouldPersistSessionInfoUpdate,
} from "./runtime";

describe("Devin ACP runtime", () => {
	test("maps ask and auto approval to normal Devin permission mode", () => {
		expect(devinPermissionMode("ask")).toBe("normal");
		expect(devinPermissionMode("auto")).toBe("normal");
	});

	test("maps full-access approval to bypass Devin permission mode", () => {
		expect(devinPermissionMode("full-access")).toBe("bypass");
	});

	test("builds the Devin ACP process command", () => {
		expect(buildDevinSpawnOptions({ approvalMode: "ask", cwd: "/tmp/project", env: {} }).cmd).toEqual([
			"devin",
			"--permission-mode",
			"normal",
			"acp",
		]);
		expect(buildDevinSpawnOptions({ approvalMode: "full-access", cwd: "/tmp/project", env: {} })).toMatchObject({
			cmd: ["devin", "--permission-mode", "bypass", "acp"],
			cwd: "/tmp/project",
			env: {},
		});
	});

	test("selects Devin by default and mock only when explicitly enabled", () => {
		expect(isAcpMockEnabled({})).toBe(false);
		expect(selectedAgentBackend({}, "devin")).toBe("devin");
		expect(isAcpMockEnabled({ LEVEL5_USE_ACP_MOCK: "1" })).toBe(true);
		expect(selectedAgentBackend({ LEVEL5_USE_ACP_MOCK: "1" }, "devin")).toBe("mock");
		expect(selectedAgentBackend({}, "omp")).toBe("omp");
		expect(selectedAgentBackend({ LEVEL5_USE_ACP_MOCK: "1" }, "omp")).toBe("mock");
	});

	test("builds the mock ACP process command without requiring Devin on PATH", () => {
		const options = buildMockSpawnOptions({
			cwd: "/tmp/project",
			env: { LEVEL5_USE_ACP_MOCK: "1", PATH: "" },
			mockStartPath: "/tmp/repo/acp-mock-server/start.sh",
		});
		expect(options.cmd).toEqual(["/tmp/repo/acp-mock-server/start.sh"]);
		expect(options.cwd).toBe("/tmp/project");
		expect(options.env.ACP_MOCK_STATE_PATH).toContain(".level5-build/acp-mock-state.json");
	});

	test("builds agent command from the selected backend", () => {
		expect(buildAgentSpawnOptions({ approvalMode: "ask", cwd: "/tmp/project", env: {} }).cmd).toEqual([
			"devin",
			"--permission-mode",
			"normal",
			"acp",
		]);
		expect(
			buildAgentSpawnOptions({
				approvalMode: "full-access",
				cwd: "/tmp/project",
				env: { LEVEL5_USE_ACP_MOCK: "1", LEVEL5_ACP_MOCK_START_PATH: "/tmp/repo/acp-mock-server/start.sh" },
			}).cmd,
		).toContain("/tmp/repo/acp-mock-server/start.sh");
		expect(buildAgentSpawnOptions({ approvalMode: "ask", cwd: "/tmp/project", env: {}, provider: "omp" }).cmd).toEqual(["omp", "acp"]);
	});

	test("builds the omp ACP process command", () => {
		expect(buildOmpSpawnOptions({ cwd: "/tmp/project", env: {} })).toMatchObject({
			cmd: ["omp", "acp"],
			cwd: "/tmp/project",
			env: {},
		});
	});

	test("normalizes unknown ACP providers conservatively", () => {
		expect(normalizeAcpProvider("omp")).toBe("omp");
		expect(normalizeAcpProvider("devin")).toBe("devin");
		expect(normalizeAcpProvider(undefined)).toBe("devin");
		expect(normalizeAcpProvider("bogus")).toBe("devin");
	});

	test("initializes with honest v1 client capabilities", () => {
		expect(AGENT_CLIENT_CAPABILITIES).toEqual({
			fs: { readTextFile: false, writeTextFile: false },
			terminal: false,
			auth: { terminal: false },
		});
	});

	test("normalizes unknown approval modes conservatively", () => {
		expect(normalizeApprovalMode("auto")).toBe("auto");
		expect(normalizeApprovalMode("unknown")).toBe("ask");
		expect(normalizeApprovalMode(undefined)).toBe("ask");
	});

	test("auto approval selects the first allow-like option", () => {
		expect(
			pickAutoApproveOptionId([
				{ optionId: "deny", name: "Deny", kind: "reject" },
				{ optionId: "allow-once", name: "Allow", kind: "allow_once" },
			]),
		).toBe("allow-once");
	});

	test("auto approval does not fall back to a reject option", () => {
		expect(
			pickAutoApproveOptionId([
				{ optionId: "deny", name: "Deny", kind: "reject_once" },
				{ optionId: "reject-always", name: "Reject always", kind: "reject_always" },
			]),
		).toBeUndefined();
	});

	test("builds ACP selected permission response shape", () => {
		expect(buildSelectedPermissionResponse("allow-once")).toEqual({
			outcome: { outcome: "selected", optionId: "allow-once" },
		});
	});

	test("missing CLI error tells the user how to recover", () => {
		expect(DEVIN_MISSING_CLI_MESSAGE).toContain("Install the Devin CLI");
		expect(DEVIN_MISSING_CLI_MESSAGE).toContain("devin auth login");
		expect(OMP_MISSING_CLI_MESSAGE).toContain("Install omp");
		expect(OMP_MISSING_CLI_MESSAGE).toContain("omp` is on PATH");
		expect(ACP_MOCK_SPAWN_FAILURE_MESSAGE).toContain("ACP mock backend");
	});

	test("missing CLI detector returns false for an empty PATH", () => {
		expect(isDevinAvailable({ PATH: "" })).toBe(false);
	});

	test("missing omp CLI detector returns false for an empty PATH", () => {
		expect(isOmpAvailable({ PATH: "" })).toBe(false);
	});
});

describe("shouldPersistSessionInfoUpdate", () => {
	test("returns false for a warm-up-only session even when the session id matches, since no message has been sent yet", () => {
		expect(
			shouldPersistSessionInfoUpdate({
				sessionId: "session-1",
				currentSessionId: "session-1",
				sessionPersisted: false,
			}),
		).toBe(false);
	});

	test("returns true once the session has been persisted and the notification matches the current session", () => {
		expect(
			shouldPersistSessionInfoUpdate({
				sessionId: "session-1",
				currentSessionId: "session-1",
				sessionPersisted: true,
			}),
		).toBe(true);
	});

	test("returns false for a stale notification whose session id no longer matches the current session, even if persisted", () => {
		expect(
			shouldPersistSessionInfoUpdate({
				sessionId: "old-session",
				currentSessionId: "new-session",
				sessionPersisted: true,
			}),
		).toBe(false);
	});

	test("returns false when there is no active session at all, regardless of sessionPersisted", () => {
		expect(
			shouldPersistSessionInfoUpdate({
				sessionId: "session-1",
				currentSessionId: null,
				sessionPersisted: true,
			}),
		).toBe(false);
		expect(
			shouldPersistSessionInfoUpdate({
				sessionId: "session-1",
				currentSessionId: null,
				sessionPersisted: false,
			}),
		).toBe(false);
	});
});
