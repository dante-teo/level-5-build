import Foundation

public struct ProjectGitStatus: Equatable, Sendable {
    public var isAvailable: Bool
    public var root: String?
    public var branch: String?
    public var isDetached: Bool
    public var changedFiles: Int
    public var additions: Int
    public var deletions: Int
    public var hasUntracked: Bool
    public var error: String?

    public init(
        isAvailable: Bool,
        root: String? = nil,
        branch: String? = nil,
        isDetached: Bool = false,
        changedFiles: Int = 0,
        additions: Int = 0,
        deletions: Int = 0,
        hasUntracked: Bool = false,
        error: String? = nil
    ) {
        self.isAvailable = isAvailable
        self.root = root
        self.branch = branch
        self.isDetached = isDetached
        self.changedFiles = changedFiles
        self.additions = additions
        self.deletions = deletions
        self.hasUntracked = hasUntracked
        self.error = error
    }

    public static func unavailable(_ message: String = "Git status is unavailable.") -> ProjectGitStatus {
        ProjectGitStatus(isAvailable: false, error: message)
    }
}

public final class ProjectGitStatusService: Sendable {
    public typealias CommandRunner = @Sendable (_ cwd: String, _ arguments: [String]) async -> GitCommandResult

    public struct GitCommandResult: Equatable, Sendable {
        public var ok: Bool
        public var stdout: String
        public var stderr: String

        public init(ok: Bool, stdout: String, stderr: String) {
            self.ok = ok
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    private static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    private let runner: CommandRunner

    public init(timeoutSeconds: TimeInterval = 3) {
        runner = { cwd, arguments in
            await Self.runGitCommand(cwd: cwd, arguments: arguments, timeoutSeconds: timeoutSeconds)
        }
    }

    public init(runner: @escaping CommandRunner) {
        self.runner = runner
    }

    public func status(cwd: String) async -> ProjectGitStatus {
        let rootResult = await runner(cwd, ["rev-parse", "--show-toplevel"])
        guard rootResult.ok else { return failedStatus(rootResult) }

        let root = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return .unavailable() }

        let statusResult = await runner(root, ["status", "--porcelain=v1", "--branch"])
        guard statusResult.ok else { return failedStatus(statusResult) }

        var porcelain = Self.parsePorcelainStatus(statusResult.stdout)
        if porcelain.isDetached {
            let detachedResult = await runner(root, ["rev-parse", "--short", "HEAD"])
            let shortSHA = detachedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if detachedResult.ok, !shortSHA.isEmpty {
                porcelain.branch = shortSHA
            }
        }

        let headResult = await runner(root, ["rev-parse", "--verify", "HEAD"])
        let diffBase = headResult.ok ? "HEAD" : Self.emptyTreeHash
        let numstatResult = await runner(root, ["diff", "--numstat", diffBase, "--"])
        guard numstatResult.ok else { return failedStatus(numstatResult) }

        let numstat = Self.parseNumstat(numstatResult.stdout)
        return ProjectGitStatus(
            isAvailable: true,
            root: root,
            branch: porcelain.branch,
            isDetached: porcelain.isDetached,
            changedFiles: porcelain.changedFiles,
            additions: numstat.additions,
            deletions: numstat.deletions,
            hasUntracked: porcelain.hasUntracked
        )
    }

    static func parsePorcelainStatus(_ output: String) -> (
        branch: String,
        isDetached: Bool,
        changedFiles: Int,
        hasUntracked: Bool
    ) {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        let branchLine = lines.first(where: { $0.hasPrefix("## ") }) ?? "## HEAD"
        let branchHeader = branchLine
            .dropFirst(3)
            .split(separator: "...", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "HEAD"
        let rawBranch: String
        if branchHeader.hasPrefix("No commits yet on ") {
            rawBranch = String(branchHeader.dropFirst("No commits yet on ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            rawBranch = branchHeader
        }
        let isDetached = rawBranch == "HEAD" || rawBranch.hasPrefix("HEAD ")
        let statusLines = lines.filter { !$0.hasPrefix("## ") }
        return (
            branch: isDetached ? "HEAD" : rawBranch,
            isDetached: isDetached,
            changedFiles: statusLines.count,
            hasUntracked: statusLines.contains { $0.hasPrefix("??") }
        )
    }

    static func parseNumstat(_ output: String) -> (additions: Int, deletions: Int) {
        output
            .split(whereSeparator: \.isNewline)
            .reduce(into: (additions: 0, deletions: 0)) { result, line in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count >= 2 else { return }
                guard columns[0] != "-", columns[1] != "-" else { return }
                result.additions += Int(columns[0]) ?? 0
                result.deletions += Int(columns[1]) ?? 0
            }
    }

    private func failedStatus(_ result: GitCommandResult) -> ProjectGitStatus {
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Git status is unavailable."
        return .unavailable(message)
    }

    private static func runGitCommand(
        cwd: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> GitCommandResult {
        await withCheckedContinuation { continuation in
            let resumeGate = ResumeGate()

            @Sendable func resume(_ result: GitCommandResult) {
                guard resumeGate.markResumed() else { return }
                continuation.resume(returning: result)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", cwd] + arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                resume(.init(ok: process.terminationStatus == 0, stdout: stdoutText, stderr: stderrText))
            }

            do {
                try process.run()
            } catch {
                resume(.init(ok: false, stdout: "", stderr: String(describing: error)))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                guard process.isRunning else { return }
                process.terminate()
                resume(.init(ok: false, stdout: "", stderr: "Git command timed out."))
            }
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
