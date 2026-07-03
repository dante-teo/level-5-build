import { describe, expect, test } from "bun:test";
import { getProjectGitStatusWithRunner, parseGitNumstat, parseGitPorcelainStatus } from "./status";

describe("project git status", () => {
	test("parses branch names from porcelain output", () => {
		expect(
			parseGitPorcelainStatus("## feature/dashboard...origin/feature/dashboard\n M src/App.tsx\n"),
		).toEqual({
			branch: "feature/dashboard",
			isDetached: false,
			changedFiles: 1,
			hasUntracked: false,
		});
	});

	test("handles detached HEAD", () => {
		expect(parseGitPorcelainStatus("## HEAD (no branch)\n M src/App.tsx\n")).toEqual({
			branch: "HEAD",
			isDetached: true,
			changedFiles: 1,
			hasUntracked: false,
		});
	});

	test("counts changed and untracked files", () => {
		expect(
			parseGitPorcelainStatus(
				[
					"## main",
					" M src/App.tsx",
					"A  src/new.ts",
					"?? scratch.txt",
					"R  old.ts -> new.ts",
					"",
				].join("\n"),
			),
		).toEqual({
			branch: "main",
			isDetached: false,
			changedFiles: 4,
			hasUntracked: true,
		});
	});

	test("sums tracked numstat additions and deletions while ignoring binary rows", () => {
		expect(parseGitNumstat("12\t3\tsrc/App.tsx\n-\t-\tasset.bin\n4\t0\tsrc/status.ts\n")).toEqual({
			additions: 16,
			deletions: 3,
		});
	});

	test("returns ok false for failed git commands", async () => {
		const result = await getProjectGitStatusWithRunner("/not-a-repo", async () => ({
			ok: false,
			stdout: "",
			stderr: "fatal: not a git repository",
		}));

		expect(result).toEqual({
			ok: false,
			error: "fatal: not a git repository",
		});
	});

	test("combines root, porcelain, and numstat results", async () => {
		const outputs = new Map([
			["rev-parse --show-toplevel", "/repo\n"],
			["status --porcelain=v1 --branch", "## main\n M src/App.tsx\n?? notes.md\n"],
			["rev-parse --verify HEAD", "abc1234\n"],
			["diff --numstat HEAD --", "5\t2\tsrc/App.tsx\n-\t-\timage.png\n"],
		]);

		const result = await getProjectGitStatusWithRunner("/repo/app", async (_cwd, args) => ({
			ok: true,
			stdout: outputs.get(args.join(" ")) ?? "",
			stderr: "",
		}));

		expect(result).toEqual({
			ok: true,
			root: "/repo",
			branch: "main",
			isDetached: false,
			changedFiles: 2,
			additions: 5,
			deletions: 2,
			hasUntracked: true,
		});
	});

	test("uses the short commit as the detached branch label", async () => {
		const outputs = new Map([
			["rev-parse --show-toplevel", "/repo\n"],
			["status --porcelain=v1 --branch", "## HEAD (no branch)\n M src/App.tsx\n"],
			["rev-parse --short HEAD", "abc1234\n"],
			["rev-parse --verify HEAD", "abc1234\n"],
			["diff --numstat HEAD --", "1\t1\tsrc/App.tsx\n"],
		]);

		const result = await getProjectGitStatusWithRunner("/repo/app", async (_cwd, args) => ({
			ok: true,
			stdout: outputs.get(args.join(" ")) ?? "",
			stderr: "",
		}));

		expect(result).toEqual({
			ok: true,
			root: "/repo",
			branch: "abc1234",
			isDetached: true,
			changedFiles: 1,
			additions: 1,
			deletions: 1,
			hasUntracked: false,
		});
	});

	test("diffs against the empty tree for repositories before the first commit", async () => {
		const emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
		const outputs = new Map([
			["rev-parse --show-toplevel", { ok: true, stdout: "/repo\n", stderr: "" }],
			["status --porcelain=v1 --branch", { ok: true, stdout: "## No commits yet on main\nA  src/App.tsx\n?? notes.md\n", stderr: "" }],
			["rev-parse --verify HEAD", { ok: false, stdout: "", stderr: "fatal: Needed a single revision\n" }],
			[`diff --numstat ${emptyTree} --`, { ok: true, stdout: "7\t0\tsrc/App.tsx\n", stderr: "" }],
		]);

		const result = await getProjectGitStatusWithRunner("/repo/app", async (_cwd, args) => (
			outputs.get(args.join(" ")) ?? { ok: false, stdout: "", stderr: `unexpected command: ${args.join(" ")}` }
		));

		expect(result).toEqual({
			ok: true,
			root: "/repo",
			branch: "main",
			isDetached: false,
			changedFiles: 2,
			additions: 7,
			deletions: 0,
			hasUntracked: true,
		});
	});
});
