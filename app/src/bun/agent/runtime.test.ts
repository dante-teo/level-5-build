import { describe, expect, test } from "bun:test";
import {
	AGENT_CLIENT_CAPABILITIES,
	DEVIN_MISSING_CLI_MESSAGE,
	buildSelectedPermissionResponse,
	buildDevinSpawnOptions,
	devinPermissionMode,
	isDevinAvailable,
	normalizeApprovalMode,
	pickAutoApproveOptionId,
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
	});

	test("missing CLI detector returns false for an empty PATH", () => {
		expect(isDevinAvailable({ PATH: "" })).toBe(false);
	});
});
