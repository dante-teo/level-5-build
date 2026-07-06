import type { ProjectGitStatus } from "../../shared/rpc";

type GitCommandResult = {
	ok: boolean;
	stdout: string;
	stderr: string;
};

type GitCommandRunner = (cwd: string, args: string[]) => Promise<GitCommandResult>;

type ParsedPorcelainStatus = Pick<
	Extract<ProjectGitStatus, { ok: true }>,
	"branch" | "isDetached" | "changedFiles" | "hasUntracked"
>;

type ParsedNumstat = Pick<Extract<ProjectGitStatus, { ok: true }>, "additions" | "deletions">;

const textDecoder = new TextDecoder();
const EMPTY_TREE_HASH = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
// Matches native's ProjectGitStatusService/ProjectReviewService default
// (app/Sources/Level5Core/ProjectGitStatus.swift, ProjectReview.swift):
// a hung git subprocess (lock contention, a blocking credential helper, a
// slow submodule fetch, etc.) must degrade to an "unavailable" state within
// a few seconds instead of hanging the status/review RPC indefinitely.
const GIT_COMMAND_TIMEOUT_MS = 3_000;

export function parseGitPorcelainStatus(output: string): ParsedPorcelainStatus {
	const lines = output.split(/\r?\n/).filter((line) => line.length > 0);
	const branchLine = lines.find((line) => line.startsWith("## ")) ?? "## HEAD";
	const branchHeader = branchLine.slice(3).split("...")[0]?.trim() || "HEAD";
	const rawBranch = branchHeader.startsWith("No commits yet on ")
		? branchHeader.replace("No commits yet on ", "").trim()
		: branchHeader;
	const isDetached = rawBranch === "HEAD" || rawBranch.startsWith("HEAD ");
	const branch = isDetached ? "HEAD" : rawBranch;
	const statusLines = lines.filter((line) => !line.startsWith("## "));

	return {
		branch,
		isDetached,
		changedFiles: statusLines.length,
		hasUntracked: statusLines.some((line) => line.startsWith("??")),
	};
}

export function parseGitNumstat(output: string): ParsedNumstat {
	return output
		.split(/\r?\n/)
		.filter((line) => line.trim().length > 0)
		.map((line) => line.split("\t"))
		.filter(([additions, deletions]) => additions !== "-" && deletions !== "-")
		.reduce(
			(total, [additions, deletions]) => ({
				additions: total.additions + Number.parseInt(additions ?? "0", 10),
				deletions: total.deletions + Number.parseInt(deletions ?? "0", 10),
			}),
			{ additions: 0, deletions: 0 },
		);
}

function spawnGit(cwd: string, args: string[]) {
	return Bun.spawn(["git", "-C", cwd, ...args], {
		stdout: "pipe",
		stderr: "pipe",
		env: process.env,
	});
}

export async function runGitCommand(
	cwd: string,
	args: string[],
	timeoutMs: number = GIT_COMMAND_TIMEOUT_MS,
): Promise<GitCommandResult> {
	let child: ReturnType<typeof spawnGit> | undefined;
	let timedOut = false;
	const timer = setTimeout(() => {
		timedOut = true;
		child?.kill();
	}, timeoutMs);
	try {
		child = spawnGit(cwd, args);
		const [stdout, stderr, exitCode] = await Promise.all([
			new Response(child.stdout).arrayBuffer(),
			new Response(child.stderr).arrayBuffer(),
			child.exited,
		]);
		if (timedOut) {
			return { ok: false, stdout: "", stderr: "Git command timed out." };
		}
		return {
			ok: exitCode === 0,
			stdout: textDecoder.decode(stdout),
			stderr: textDecoder.decode(stderr),
		};
	} catch (error) {
		return {
			ok: false,
			stdout: "",
			stderr: error instanceof Error ? error.message : "Failed to run git.",
		};
	} finally {
		clearTimeout(timer);
	}
}

function failedStatus(result: GitCommandResult): ProjectGitStatus {
	return {
		ok: false,
		error: result.stderr.trim() || result.stdout.trim() || "Git status is unavailable.",
	};
}

export async function getProjectGitStatusWithRunner(
	cwd: string,
	run: GitCommandRunner,
): Promise<ProjectGitStatus> {
	const rootResult = await run(cwd, ["rev-parse", "--show-toplevel"]);
	if (!rootResult.ok) {
		return failedStatus(rootResult);
	}

	const root = rootResult.stdout.trim();
	const statusResult = await run(root, ["status", "--porcelain=v1", "--branch"]);
	if (!statusResult.ok) {
		return failedStatus(statusResult);
	}
	const porcelain = parseGitPorcelainStatus(statusResult.stdout);
	const detachedHeadResult = porcelain.isDetached ? await run(root, ["rev-parse", "--short", "HEAD"]) : null;
	const branch =
		porcelain.isDetached && detachedHeadResult?.ok && detachedHeadResult.stdout.trim()
			? detachedHeadResult.stdout.trim()
			: porcelain.branch;
	const headResult = await run(root, ["rev-parse", "--verify", "HEAD"]);
	const diffBase = headResult.ok ? "HEAD" : EMPTY_TREE_HASH;

	const numstatResult = await run(root, ["diff", "--numstat", diffBase, "--"]);
	if (!numstatResult.ok) {
		return failedStatus(numstatResult);
	}

	return {
		ok: true,
		root,
		...porcelain,
		branch,
		...parseGitNumstat(numstatResult.stdout),
	};
}

export function getProjectGitStatus(cwd: string): Promise<ProjectGitStatus> {
	return getProjectGitStatusWithRunner(cwd, runGitCommand);
}
