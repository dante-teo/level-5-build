import { describe, expect, test } from "bun:test";
import {
	DIFF_BYTE_LIMIT,
	FILE_LIMIT,
	changeKindFor,
	getFileDiffPreviewWithRunner,
	getProjectReviewSnapshotWithRunner,
	hasStagedChanges,
	hasUnstagedChanges,
	isImagePath,
	isMixedChange,
	isUntrackedFile,
	parseReviewNumstat,
	parseReviewStatusFiles,
	statusBadge,
	type ProjectChangedFile,
	type ReviewFileSystem,
	type ReviewFileSystemEntry,
} from "./review";

function fakeFileSystem(overrides: Partial<ReviewFileSystem> = {}): ReviewFileSystem {
	return {
		stat: async () => null,
		exists: async () => false,
		readFile: async () => null,
		readlink: async () => null,
		...overrides,
	};
}

function fileEntry(overrides: Partial<ReviewFileSystemEntry> = {}): ReviewFileSystemEntry {
	return { isDirectory: false, isSymbolicLink: false, size: 0, ...overrides };
}

function baseFile(overrides: Partial<ProjectChangedFile> = {}): ProjectChangedFile {
	return {
		path: "src/App.tsx",
		indexStatus: " ",
		workingTreeStatus: "M",
		changeKind: "modified",
		contentKind: "text",
		additions: 0,
		deletions: 0,
		...overrides,
	};
}

describe("changeKindFor", () => {
	test.each([
		["?", "?", "untracked"],
		["R", " ", "renamed"],
		["C", " ", "copied"],
		["D", " ", "deleted"],
		["A", " ", "added"],
		["T", " ", "typeChanged"],
		["M", " ", "modified"],
		["!", "!", "unknown"],
	] as const)("(%s, %s) -> %s", (indexStatus, workingTreeStatus, expected) => {
		expect(changeKindFor(indexStatus, workingTreeStatus)).toBe(expected);
	});
});

describe("isImagePath", () => {
	test("recognizes common image extensions case-insensitively", () => {
		expect(isImagePath("logo.PNG")).toBe(true);
		expect(isImagePath("photo.jpeg")).toBe(true);
		expect(isImagePath("notes.md")).toBe(false);
	});
});

describe("status predicates", () => {
	test("hasStagedChanges / hasUnstagedChanges / isMixedChange", () => {
		const staged = baseFile({ indexStatus: "M", workingTreeStatus: " " });
		const unstaged = baseFile({ indexStatus: " ", workingTreeStatus: "M" });
		const mixed = baseFile({ indexStatus: "M", workingTreeStatus: "M" });
		expect(hasStagedChanges(staged)).toBe(true);
		expect(hasUnstagedChanges(staged)).toBe(false);
		expect(hasStagedChanges(unstaged)).toBe(false);
		expect(hasUnstagedChanges(unstaged)).toBe(true);
		expect(isMixedChange(mixed)).toBe(true);
	});

	test("isUntrackedFile requires both columns to be ?", () => {
		expect(isUntrackedFile(baseFile({ indexStatus: "?", workingTreeStatus: "?" }))).toBe(true);
		expect(isUntrackedFile(baseFile({ indexStatus: "?", workingTreeStatus: " " }))).toBe(false);
	});

	test("statusBadge precedence: untracked > mixed > staged > unstaged > changed", () => {
		expect(statusBadge(baseFile({ indexStatus: "?", workingTreeStatus: "?" }))).toBe("Untracked");
		expect(statusBadge(baseFile({ indexStatus: "M", workingTreeStatus: "M" }))).toBe("Mixed");
		expect(statusBadge(baseFile({ indexStatus: "M", workingTreeStatus: " " }))).toBe("Staged");
		expect(statusBadge(baseFile({ indexStatus: " ", workingTreeStatus: "M" }))).toBe("Unstaged");
	});
});

describe("parseReviewStatusFiles", () => {
	test("parses modified, added, deleted, and untracked rows", () => {
		const output = [
			"## main...origin/main",
			" M src/App.tsx",
			"A  src/new.ts",
			" D src/old.ts",
			"?? scratch.txt",
			"",
		].join("\n");

		const files = parseReviewStatusFiles(output);
		expect(files).toHaveLength(4);
		expect(files[0]).toMatchObject({ path: "src/App.tsx", changeKind: "modified" });
		expect(files[1]).toMatchObject({ path: "src/new.ts", changeKind: "added" });
		expect(files[2]).toMatchObject({ path: "src/old.ts", changeKind: "deleted" });
		expect(files[3]).toMatchObject({ path: "scratch.txt", changeKind: "untracked" });
	});

	test("splits renamed rows into oldPath and path", () => {
		const files = parseReviewStatusFiles("R  old.ts -> new.ts\n");
		expect(files).toEqual([
			expect.objectContaining({ oldPath: "old.ts", path: "new.ts", changeKind: "renamed" }),
		]);
	});
});

describe("parseReviewNumstat", () => {
	test("parses additions/deletions and flags binary rows", () => {
		const numstat = parseReviewNumstat("5\t2\t\0src/App.tsx\0-\t-\t\0image.png\0");
		expect(numstat.get("src/App.tsx")).toEqual({ additions: 5, deletions: 2, isBinary: false });
		expect(numstat.get("image.png")).toEqual({ additions: 0, deletions: 0, isBinary: true });
	});

	test("keys a renamed-and-edited file by its new path, not the old one", () => {
		// -z emits two NUL-terminated path fields (old, then new) for a
		// rename instead of a single ambiguous "old => new" string.
		const numstat = parseReviewNumstat("6\t6\t\0src/foo.txt\0src/bar.txt\0");
		expect(numstat.get("src/bar.txt")).toEqual({ additions: 6, deletions: 6, isBinary: false });
		expect(numstat.get("src/foo.txt")).toBeUndefined();
	});
});

describe("getProjectReviewSnapshotWithRunner", () => {
	test("returns an unavailable snapshot when the folder is not a git repository", async () => {
		const result = await getProjectReviewSnapshotWithRunner(
			"/not/a/repo",
			async () => ({ ok: false, stdout: "", stderr: "fatal: not a git repository" }),
		);
		expect(result).toEqual({ isAvailable: false, error: { message: "fatal: not a git repository", rawOutput: "fatal: not a git repository" } });
	});

	test("builds a sorted snapshot with enriched files", async () => {
		const outputs = new Map<string, { ok: boolean; stdout: string; stderr: string }>([
			["rev-parse --show-toplevel", { ok: true, stdout: "/repo\n", stderr: "" }],
			[
				"status --porcelain=v1 --branch --untracked-files=all",
				{ ok: true, stdout: "## feature/x\n M src/b.ts\n?? src/a.ts\n", stderr: "" },
			],
			["rev-parse --verify HEAD", { ok: true, stdout: "abc123\n", stderr: "" }],
			["diff --numstat -z HEAD --", { ok: true, stdout: "3\t1\t\0src/b.ts\0", stderr: "" }],
		]);
		const run = async (_cwd: string, args: string[]) =>
			outputs.get(args.join(" ")) ?? { ok: false, stdout: "", stderr: `unexpected: ${args.join(" ")}` };

		const snapshot = await getProjectReviewSnapshotWithRunner("/repo/app", run, fakeFileSystem());
		if (!snapshot.isAvailable) throw new Error("expected an available snapshot");

		expect(snapshot.root).toBe("/repo");
		expect(snapshot.branch).toBe("feature/x");
		expect(snapshot.isDetached).toBe(false);
		expect(snapshot.totalChangedFiles).toBe(2);
		expect(snapshot.overflowCount).toBe(0);
		// Sorted by path: src/a.ts before src/b.ts.
		expect(snapshot.files.map((file) => file.path)).toEqual(["src/a.ts", "src/b.ts"]);
		expect(snapshot.files[1]).toMatchObject({ additions: 3, deletions: 1, contentKind: "text" });
	});

	test("uses the short commit as the detached branch label", async () => {
		const outputs = new Map<string, { ok: boolean; stdout: string; stderr: string }>([
			["rev-parse --show-toplevel", { ok: true, stdout: "/repo\n", stderr: "" }],
			[
				"status --porcelain=v1 --branch --untracked-files=all",
				{ ok: true, stdout: "## HEAD (no branch)\n M src/b.ts\n", stderr: "" },
			],
			["rev-parse --short HEAD", { ok: true, stdout: "abc1234\n", stderr: "" }],
			["rev-parse --verify HEAD", { ok: true, stdout: "abc1234\n", stderr: "" }],
			["diff --numstat -z HEAD --", { ok: true, stdout: "1\t1\t\0src/b.ts\0", stderr: "" }],
		]);
		const run = async (_cwd: string, args: string[]) =>
			outputs.get(args.join(" ")) ?? { ok: false, stdout: "", stderr: `unexpected: ${args.join(" ")}` };

		const snapshot = await getProjectReviewSnapshotWithRunner("/repo", run, fakeFileSystem());
		if (!snapshot.isAvailable) throw new Error("expected an available snapshot");
		expect(snapshot.isDetached).toBe(true);
		expect(snapshot.branch).toBe("abc1234");
	});

	test("caps rendered files at FILE_LIMIT and reports overflow", async () => {
		const statusLines = Array.from({ length: FILE_LIMIT + 10 }, (_, index) => ` M src/file-${String(index).padStart(4, "0")}.ts`);
		const outputs = new Map<string, { ok: boolean; stdout: string; stderr: string }>([
			["rev-parse --show-toplevel", { ok: true, stdout: "/repo\n", stderr: "" }],
			[
				"status --porcelain=v1 --branch --untracked-files=all",
				{ ok: true, stdout: `## main\n${statusLines.join("\n")}\n`, stderr: "" },
			],
			["rev-parse --verify HEAD", { ok: true, stdout: "abc\n", stderr: "" }],
			["diff --numstat -z HEAD --", { ok: true, stdout: "", stderr: "" }],
		]);
		const run = async (_cwd: string, args: string[]) =>
			outputs.get(args.join(" ")) ?? { ok: false, stdout: "", stderr: `unexpected: ${args.join(" ")}` };

		const snapshot = await getProjectReviewSnapshotWithRunner("/repo", run, fakeFileSystem());
		if (!snapshot.isAvailable) throw new Error("expected an available snapshot");
		expect(snapshot.totalChangedFiles).toBe(FILE_LIMIT + 10);
		expect(snapshot.files).toHaveLength(FILE_LIMIT);
		expect(snapshot.overflowCount).toBe(10);
	});

	test("marks a directory containing .git as a submodule", async () => {
		const outputs = new Map<string, { ok: boolean; stdout: string; stderr: string }>([
			["rev-parse --show-toplevel", { ok: true, stdout: "/repo\n", stderr: "" }],
			[
				"status --porcelain=v1 --branch --untracked-files=all",
				{ ok: true, stdout: "## main\n?? vendor/lib\n", stderr: "" },
			],
			["rev-parse --verify HEAD", { ok: true, stdout: "abc\n", stderr: "" }],
			["diff --numstat -z HEAD --", { ok: true, stdout: "", stderr: "" }],
		]);
		const run = async (_cwd: string, args: string[]) =>
			outputs.get(args.join(" ")) ?? { ok: false, stdout: "", stderr: `unexpected: ${args.join(" ")}` };
		const fs = fakeFileSystem({
			stat: async (path) => (path.endsWith("vendor/lib") ? fileEntry({ isDirectory: true }) : null),
			exists: async (path) => path.endsWith("vendor/lib/.git"),
		});

		const snapshot = await getProjectReviewSnapshotWithRunner("/repo", run, fs);
		if (!snapshot.isAvailable) throw new Error("expected an available snapshot");
		expect(snapshot.files[0]).toMatchObject({ path: "vendor/lib", contentKind: "submodule" });
	});

	test("assigns numstat additions/deletions to a renamed-and-edited file's new path", async () => {
		const outputs = new Map<string, { ok: boolean; stdout: string; stderr: string }>([
			["rev-parse --show-toplevel", { ok: true, stdout: "/repo\n", stderr: "" }],
			[
				"status --porcelain=v1 --branch --untracked-files=all",
				{ ok: true, stdout: "## main\nR  src/foo.txt -> src/bar.txt\n", stderr: "" },
			],
			["rev-parse --verify HEAD", { ok: true, stdout: "abc\n", stderr: "" }],
			["diff --numstat -z HEAD --", { ok: true, stdout: "6\t6\t\0src/foo.txt\0src/bar.txt\0", stderr: "" }],
		]);
		const run = async (_cwd: string, args: string[]) =>
			outputs.get(args.join(" ")) ?? { ok: false, stdout: "", stderr: `unexpected: ${args.join(" ")}` };

		const snapshot = await getProjectReviewSnapshotWithRunner("/repo", run, fakeFileSystem());
		if (!snapshot.isAvailable) throw new Error("expected an available snapshot");
		expect(snapshot.files[0]).toMatchObject({ path: "src/bar.txt", additions: 6, deletions: 6 });
	});
});

describe("getFileDiffPreviewWithRunner", () => {
	const runnerFor = (diffStdout: string) => async (_cwd: string, args: string[]) => {
		if (args[0] === "rev-parse" && args[1] === "--show-toplevel") return { ok: true, stdout: "/repo\n", stderr: "" };
		if (args[0] === "rev-parse" && args[1] === "--verify") return { ok: true, stdout: "abc\n", stderr: "" };
		if (args[0] === "diff") return { ok: true, stdout: diffStdout, stderr: "" };
		return { ok: false, stdout: "", stderr: `unexpected: ${args.join(" ")}` };
	};

	test("returns a unified diff for a tracked text file", async () => {
		const diff = "diff --git a/src/App.tsx b/src/App.tsx\n@@ -1 +1 @@\n-old\n+new\n";
		const preview = await getFileDiffPreviewWithRunner("/repo", baseFile(), runnerFor(diff), fakeFileSystem());
		expect(preview.content).toEqual({ kind: "unifiedDiff", diff });
	});

	test("returns metadata for a submodule without shelling out to diff", async () => {
		const file = baseFile({ contentKind: "submodule" });
		const preview = await getFileDiffPreviewWithRunner("/repo", file, runnerFor("should not be used"), fakeFileSystem());
		expect(preview.content).toEqual({
			kind: "metadata",
			message: "Nested repositories and submodules are shown as metadata only.",
		});
	});

	test("returns metadata for a binary file", async () => {
		const file = baseFile({ contentKind: "binary" });
		const preview = await getFileDiffPreviewWithRunner("/repo", file, runnerFor("should not be used"), fakeFileSystem());
		expect(preview.content).toEqual({ kind: "metadata", message: "Binary file preview is not supported." });
	});

	test("returns an image preview for a changed (not deleted) image file that exists on disk", async () => {
		const file = baseFile({ path: "logo.png", contentKind: "image", byteSize: 1024 });
		const fs = fakeFileSystem({ exists: async () => true });
		const preview = await getFileDiffPreviewWithRunner("/repo", file, runnerFor("unused"), fs);
		expect(preview.content).toEqual({ kind: "image", path: "/repo/logo.png", byteSize: 1024 });
	});

	test("returns a too-large state for a diff over the byte limit", async () => {
		const file = baseFile({ byteSize: DIFF_BYTE_LIMIT + 1 });
		const preview = await getFileDiffPreviewWithRunner("/repo", file, runnerFor("unused"), fakeFileSystem());
		expect(preview.content).toEqual({ kind: "tooLarge", byteSize: DIFF_BYTE_LIMIT + 1, limit: DIFF_BYTE_LIMIT });
	});

	test("surfaces a friendly error when git diff fails", async () => {
		const run = async (_cwd: string, args: string[]) => {
			if (args[0] === "rev-parse" && args[1] === "--show-toplevel") return { ok: true, stdout: "/repo\n", stderr: "" };
			if (args[0] === "rev-parse" && args[1] === "--verify") return { ok: true, stdout: "abc\n", stderr: "" };
			return { ok: false, stdout: "", stderr: "fatal: bad revision" };
		};
		const preview = await getFileDiffPreviewWithRunner("/repo", baseFile(), run, fakeFileSystem());
		expect(preview.content).toEqual({
			kind: "error",
			error: { message: "fatal: bad revision", rawOutput: "fatal: bad revision" },
		});
	});

	test("synthesizes a new-file diff for an untracked text file", async () => {
		const file = baseFile({ path: "notes.md", indexStatus: "?", workingTreeStatus: "?", contentKind: "text" });
		const fs = fakeFileSystem({ readFile: async () => Buffer.from("hello\nworld") });
		const preview = await getFileDiffPreviewWithRunner("/repo", file, runnerFor("unused"), fs);
		expect(preview.content).toEqual({
			kind: "unifiedDiff",
			diff: [
				"diff --git a/notes.md b/notes.md",
				"new file mode 100644",
				"--- /dev/null",
				"+++ b/notes.md",
				"@@ -0,0 +1,2 @@",
				"+hello\n+world",
			].join("\n"),
		});
	});

	test("synthesizes a symlink diff for an untracked symlink", async () => {
		const file = baseFile({
			path: "link",
			indexStatus: "?",
			workingTreeStatus: "?",
			contentKind: "symlink",
		});
		const fs = fakeFileSystem({ readlink: async () => "target.txt" });
		const preview = await getFileDiffPreviewWithRunner("/repo", file, runnerFor("unused"), fs);
		expect(preview.content).toEqual({
			kind: "unifiedDiff",
			diff: ["diff --git a/link b/link", "new file mode 120000", "--- /dev/null", "+++ b/link", "@@ -0,0 +1 @@", "+target.txt"].join(
				"\n",
			),
		});
	});

	test("treats an untracked file containing a null byte as binary", async () => {
		const file = baseFile({ path: "blob.bin", indexStatus: "?", workingTreeStatus: "?", contentKind: "text" });
		const fs = fakeFileSystem({ readFile: async () => Buffer.from([0x00, 0x01, 0x02]) });
		const preview = await getFileDiffPreviewWithRunner("/repo", file, runnerFor("unused"), fs);
		expect(preview.content).toEqual({ kind: "metadata", message: "Binary file preview is not supported." });
	});
});
