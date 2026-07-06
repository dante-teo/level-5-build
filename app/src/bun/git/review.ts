import { access, lstat, readFile as fsReadFile, readlink as fsReadlink } from "node:fs/promises";
import { resolve } from "node:path";
import type {
	ChangeKind,
	ContentKind,
	ProjectChangedFile,
	ProjectFilePreview,
	ProjectReviewError,
	ProjectReviewSnapshot,
} from "../../shared/rpc";
import { parseGitPorcelainStatus, runGitCommand } from "./status";

// Ports app/Sources/Level5Core/ProjectReview.swift (ProjectReviewService) to
// TypeScript. Review is Git working-tree based and inspect-only: it never
// stages, discards, commits, reverts, or answers permissions. Result shapes
// live in ../../shared/rpc so both the bun and mainview sides agree on them.

export type { ChangeKind, ContentKind, ProjectChangedFile, ProjectFilePreview, ProjectReviewError, ProjectReviewSnapshot };

type GitCommandResult = { ok: boolean; stdout: string; stderr: string };
export type ReviewGitRunner = (cwd: string, args: string[]) => Promise<GitCommandResult>;

export type ReviewFileSystemEntry = {
	isDirectory: boolean;
	isSymbolicLink: boolean;
	size: number;
};

export type ReviewFileSystem = {
	stat(path: string): Promise<ReviewFileSystemEntry | null>;
	exists(path: string): Promise<boolean>;
	readFile(path: string): Promise<Buffer | null>;
	readlink(path: string): Promise<string | null>;
};

export const nodeReviewFileSystem: ReviewFileSystem = {
	// lstat (not stat) so a symlink itself is detected rather than followed,
	// matching the native FileManager.attributesOfItem(atPath:) contract.
	async stat(path) {
		try {
			const stats = await lstat(path);
			return { isDirectory: stats.isDirectory(), isSymbolicLink: stats.isSymbolicLink(), size: stats.size };
		} catch {
			return null;
		}
	},
	async exists(path) {
		try {
			await access(path);
			return true;
		} catch {
			return false;
		}
	},
	async readFile(path) {
		try {
			return await fsReadFile(path);
		} catch {
			return null;
		}
	},
	async readlink(path) {
		try {
			return await fsReadlink(path);
		} catch {
			return null;
		}
	},
};

export const FILE_LIMIT = 500;
export const DIFF_BYTE_LIMIT = 200 * 1024;
const EMPTY_TREE_HASH = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"]);

export function changeKindFor(indexStatus: string, workingTreeStatus: string): ChangeKind {
	if (indexStatus === "?" && workingTreeStatus === "?") return "untracked";
	if (indexStatus === "R" || workingTreeStatus === "R") return "renamed";
	if (indexStatus === "C" || workingTreeStatus === "C") return "copied";
	if (indexStatus === "D" || workingTreeStatus === "D") return "deleted";
	if (indexStatus === "A" || workingTreeStatus === "A") return "added";
	if (indexStatus === "T" || workingTreeStatus === "T") return "typeChanged";
	if (indexStatus === "M" || workingTreeStatus === "M") return "modified";
	return "unknown";
}

export function isImagePath(path: string): boolean {
	const extension = path.split(".").pop()?.toLowerCase() ?? "";
	return IMAGE_EXTENSIONS.has(extension);
}

export function hasStagedChanges(file: ProjectChangedFile): boolean {
	return file.indexStatus !== " " && file.indexStatus !== "?";
}

export function hasUnstagedChanges(file: ProjectChangedFile): boolean {
	return file.workingTreeStatus !== " " && file.workingTreeStatus !== "?";
}

export function isUntrackedFile(file: ProjectChangedFile): boolean {
	return file.indexStatus === "?" && file.workingTreeStatus === "?";
}

export function isMixedChange(file: ProjectChangedFile): boolean {
	return hasStagedChanges(file) && hasUnstagedChanges(file);
}

export function statusBadge(file: ProjectChangedFile): "Untracked" | "Mixed" | "Staged" | "Unstaged" | "Changed" {
	if (isUntrackedFile(file)) return "Untracked";
	if (isMixedChange(file)) return "Mixed";
	if (hasStagedChanges(file)) return "Staged";
	if (hasUnstagedChanges(file)) return "Unstaged";
	return "Changed";
}

export function parseReviewStatusFiles(output: string): ProjectChangedFile[] {
	return output
		.split(/\r?\n/)
		.filter((line) => line.length >= 3 && !line.startsWith("## "))
		.map((line) => {
			const indexStatus = line[0] ?? " ";
			const workingTreeStatus = line[1] ?? " ";
			const rawPath = line.slice(3);
			let oldPath: string | undefined;
			let path = rawPath;
			if ((indexStatus === "R" || indexStatus === "C") && rawPath.includes(" -> ")) {
				const separatorIndex = rawPath.indexOf(" -> ");
				oldPath = rawPath.slice(0, separatorIndex);
				path = rawPath.slice(separatorIndex + " -> ".length);
			}
			return {
				path,
				oldPath,
				indexStatus,
				workingTreeStatus,
				changeKind: changeKindFor(indexStatus, workingTreeStatus),
				contentKind: "unknown" as ContentKind,
				additions: 0,
				deletions: 0,
			};
		});
}

export type NumstatEntry = { additions: number; deletions: number; isBinary: boolean };

// Parses `git diff --numstat -z` output. The `-z` flag is required, not
// cosmetic: without it, a renamed-and-edited file (at or above git's
// similarity threshold) prints as a single compact line like
// `6\t6\tsrc/{foo.txt => bar.txt}` with no unambiguous path field to key
// this map by, silently orphaning that file's stats from `enrichFile`'s
// lookup by `file.path`. With `-z`, git instead NUL-terminates the numstat
// fields and then the path(s) -- two NUL-terminated paths (old, then new)
// for a rename, one otherwise -- so the destination path is always
// extractable and matches the porcelain-status-derived `file.path`.
const NUMSTAT_RECORD_PATTERN = /^(-|\d+)\t(-|\d+)\t$/;

export function parseReviewNumstat(output: string): Map<string, NumstatEntry> {
	const result = new Map<string, NumstatEntry>();
	const fields = output.split("\0").filter((field) => field.length > 0);
	let index = 0;
	while (index < fields.length) {
		const record = fields[index] ?? "";
		const match = record.match(NUMSTAT_RECORD_PATTERN);
		if (!match) {
			// Not a numstat record; skip forward defensively.
			index += 1;
			continue;
		}
		const isBinary = match[1] === "-" || match[2] === "-";
		const firstPath = fields[index + 1];
		const secondPath = fields[index + 2];
		// A rename's second path field is a genuine path, never a numstat
		// record (which always matches NUMSTAT_RECORD_PATTERN); anything
		// else means this entry had only one path.
		const isRename = secondPath !== undefined && !NUMSTAT_RECORD_PATTERN.test(secondPath);
		const path = isRename ? secondPath : firstPath;
		index += isRename ? 3 : 2;
		if (path === undefined) continue;
		result.set(path, {
			additions: isBinary ? 0 : Number.parseInt(match[1] ?? "0", 10) || 0,
			deletions: isBinary ? 0 : Number.parseInt(match[2] ?? "0", 10) || 0,
			isBinary,
		});
	}
	return result;
}

function reviewError(result: GitCommandResult, fallback: string): ProjectReviewError {
	const raw = [result.stderr, result.stdout]
		.map((value) => value.trim())
		.filter((value) => value.length > 0)
		.join("\n");
	return raw ? { message: raw, rawOutput: raw } : { message: fallback };
}

function unavailable(error: ProjectReviewError): ProjectReviewSnapshot {
	return { isAvailable: false, error };
}

async function enrichFile(
	file: ProjectChangedFile,
	root: string,
	numstat: Map<string, NumstatEntry>,
	fs: ReviewFileSystem,
): Promise<ProjectChangedFile> {
	const stats = numstat.get(file.path);
	const absolutePath = resolve(root, file.path);
	const entry = await fs.stat(absolutePath);
	const isNestedRepository = Boolean(entry?.isDirectory) && (await fs.exists(resolve(absolutePath, ".git")));

	let contentKind: ContentKind;
	if (isNestedRepository) {
		contentKind = "submodule";
	} else if (entry?.isSymbolicLink) {
		contentKind = "symlink";
	} else if (stats?.isBinary) {
		contentKind = isImagePath(file.path) ? "image" : "binary";
	} else if (isImagePath(file.path) && file.changeKind !== "deleted") {
		contentKind = "image";
	} else {
		contentKind = "text";
	}

	return {
		...file,
		contentKind,
		additions: stats?.additions ?? 0,
		deletions: stats?.deletions ?? 0,
		byteSize: entry?.size,
	};
}

async function gitRoot(cwd: string, run: ReviewGitRunner): Promise<string | null> {
	const result = await run(cwd, ["rev-parse", "--show-toplevel"]);
	if (!result.ok) return null;
	const root = result.stdout.trim();
	return root || null;
}

export async function getProjectReviewSnapshotWithRunner(
	cwd: string,
	run: ReviewGitRunner,
	fs: ReviewFileSystem = nodeReviewFileSystem,
): Promise<ProjectReviewSnapshot> {
	const rootResult = await run(cwd, ["rev-parse", "--show-toplevel"]);
	if (!rootResult.ok) {
		return unavailable(reviewError(rootResult, "Review is unavailable for this folder."));
	}
	const root = rootResult.stdout.trim();
	if (!root) {
		return unavailable({ message: "Review is unavailable for this folder." });
	}

	const statusResult = await run(root, ["status", "--porcelain=v1", "--branch", "--untracked-files=all"]);
	if (!statusResult.ok) {
		return unavailable(reviewError(statusResult, "Git status could not be read."));
	}
	const header = parseGitPorcelainStatus(statusResult.stdout);
	let branch: string | null = header.branch;
	if (header.isDetached) {
		const detachedResult = await run(root, ["rev-parse", "--short", "HEAD"]);
		const shortSha = detachedResult.stdout.trim();
		if (detachedResult.ok && shortSha) {
			branch = shortSha;
		}
	}

	const headResult = await run(root, ["rev-parse", "--verify", "HEAD"]);
	const diffBase = headResult.ok ? "HEAD" : EMPTY_TREE_HASH;
	const numstatResult = await run(root, ["diff", "--numstat", "-z", diffBase, "--"]);
	if (!numstatResult.ok) {
		return unavailable(reviewError(numstatResult, "Git diff could not be read."));
	}
	const numstat = parseReviewNumstat(numstatResult.stdout);

	const parsedFiles = parseReviewStatusFiles(statusResult.stdout);
	const enrichedFiles = await Promise.all(parsedFiles.map((file) => enrichFile(file, root, numstat, fs)));
	const allFiles = [...enrichedFiles].sort((left, right) => left.path.localeCompare(right.path));
	const visibleFiles = allFiles.slice(0, FILE_LIMIT);

	return {
		isAvailable: true,
		root,
		branch,
		isDetached: header.isDetached,
		files: visibleFiles,
		totalChangedFiles: allFiles.length,
		overflowCount: Math.max(0, allFiles.length - visibleFiles.length),
	};
}

async function synthesizeUntrackedPreview(
	file: ProjectChangedFile,
	absolutePath: string,
	fs: ReviewFileSystem,
): Promise<ProjectFilePreview> {
	if (file.contentKind === "symlink") {
		const target = (await fs.readlink(absolutePath)) ?? "";
		const diff = [
			`diff --git a/${file.path} b/${file.path}`,
			"new file mode 120000",
			"--- /dev/null",
			`+++ b/${file.path}`,
			"@@ -0,0 +1 @@",
			`+${target}`,
		].join("\n");
		return { file, content: { kind: "unifiedDiff", diff } };
	}

	const data = await fs.readFile(absolutePath);
	if (data === null) {
		return { file, content: { kind: "error", error: { message: "File could not be read." } } };
	}
	if (data.byteLength > DIFF_BYTE_LIMIT) {
		return { file, content: { kind: "tooLarge", byteSize: data.byteLength, limit: DIFF_BYTE_LIMIT } };
	}
	if (data.includes(0)) {
		return { file, content: { kind: "metadata", message: "Binary file preview is not supported." } };
	}

	const lines = data.toString("utf8").split("\n");
	const body = lines.map((line) => `+${line}`).join("\n");
	const diff = [
		`diff --git a/${file.path} b/${file.path}`,
		"new file mode 100644",
		"--- /dev/null",
		`+++ b/${file.path}`,
		`@@ -0,0 +1,${Math.max(lines.length, 1)} @@`,
		body,
	].join("\n");
	return { file, content: { kind: "unifiedDiff", diff } };
}

export async function getFileDiffPreviewWithRunner(
	cwd: string,
	file: ProjectChangedFile,
	run: ReviewGitRunner,
	fs: ReviewFileSystem = nodeReviewFileSystem,
): Promise<ProjectFilePreview> {
	const root = (await gitRoot(cwd, run)) ?? cwd;
	const absolutePath = resolve(root, file.path);

	if (file.contentKind === "submodule") {
		return {
			file,
			content: { kind: "metadata", message: "Nested repositories and submodules are shown as metadata only." },
		};
	}
	if (file.contentKind === "image" && file.changeKind !== "deleted" && (await fs.exists(absolutePath))) {
		return { file, content: { kind: "image", path: absolutePath, byteSize: file.byteSize } };
	}
	if (file.contentKind === "binary") {
		return { file, content: { kind: "metadata", message: "Binary file preview is not supported." } };
	}
	if (file.byteSize !== undefined && file.byteSize > DIFF_BYTE_LIMIT) {
		return { file, content: { kind: "tooLarge", byteSize: file.byteSize, limit: DIFF_BYTE_LIMIT } };
	}
	if (isUntrackedFile(file)) {
		return synthesizeUntrackedPreview(file, absolutePath, fs);
	}

	const headResult = await run(root, ["rev-parse", "--verify", "HEAD"]);
	const diffBase = headResult.ok ? "HEAD" : EMPTY_TREE_HASH;
	const result = await run(root, ["diff", "--no-ext-diff", "--no-color", diffBase, "--", file.path]);
	if (!result.ok) {
		return { file, content: { kind: "error", error: reviewError(result, "Diff could not be loaded.") } };
	}
	const diffByteLength = Buffer.byteLength(result.stdout, "utf8");
	if (diffByteLength > DIFF_BYTE_LIMIT) {
		return { file, content: { kind: "tooLarge", byteSize: diffByteLength, limit: DIFF_BYTE_LIMIT } };
	}
	return {
		file,
		content: { kind: "unifiedDiff", diff: result.stdout.trim().length > 0 ? result.stdout : "No textual diff is available." },
	};
}

export function getProjectReviewSnapshot(cwd: string): Promise<ProjectReviewSnapshot> {
	return getProjectReviewSnapshotWithRunner(cwd, runGitCommand);
}

export function getFileDiffPreview(cwd: string, file: ProjectChangedFile): Promise<ProjectFilePreview> {
	return getFileDiffPreviewWithRunner(cwd, file, runGitCommand);
}
