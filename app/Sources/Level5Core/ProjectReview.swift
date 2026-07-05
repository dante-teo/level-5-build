import Foundation

public struct ProjectReviewSnapshot: Equatable, Sendable {
    public var isAvailable: Bool
    public var root: String?
    public var branch: String?
    public var isDetached: Bool
    public var files: [ProjectChangedFile]
    public var totalChangedFiles: Int
    public var overflowCount: Int
    public var error: ProjectReviewError?

    public init(
        isAvailable: Bool,
        root: String? = nil,
        branch: String? = nil,
        isDetached: Bool = false,
        files: [ProjectChangedFile] = [],
        totalChangedFiles: Int = 0,
        overflowCount: Int = 0,
        error: ProjectReviewError? = nil
    ) {
        self.isAvailable = isAvailable
        self.root = root
        self.branch = branch
        self.isDetached = isDetached
        self.files = files
        self.totalChangedFiles = totalChangedFiles
        self.overflowCount = overflowCount
        self.error = error
    }

    public static func unavailable(_ message: String, rawOutput: String? = nil) -> ProjectReviewSnapshot {
        ProjectReviewSnapshot(
            isAvailable: false,
            error: .init(message: message, rawOutput: rawOutput)
        )
    }
}

public struct ProjectReviewError: Equatable, Sendable {
    public var message: String
    public var rawOutput: String?

    public init(message: String, rawOutput: String? = nil) {
        self.message = message
        self.rawOutput = rawOutput
    }
}

public struct ProjectChangedFile: Identifiable, Equatable, Sendable {
    public enum ChangeKind: String, Equatable, Sendable {
        case added
        case modified
        case deleted
        case renamed
        case copied
        case untracked
        case typeChanged
        case unknown
    }

    public enum ContentKind: String, Equatable, Sendable {
        case text
        case image
        case binary
        case submodule
        case symlink
        case unknown
    }

    public var id: String { oldPath.map { "\($0)->\(path)" } ?? path }
    public var path: String
    public var oldPath: String?
    public var indexStatus: Character
    public var workingTreeStatus: Character
    public var changeKind: ChangeKind
    public var contentKind: ContentKind
    public var additions: Int
    public var deletions: Int
    public var byteSize: Int?

    public init(
        path: String,
        oldPath: String? = nil,
        indexStatus: Character = " ",
        workingTreeStatus: Character = " ",
        changeKind: ChangeKind,
        contentKind: ContentKind = .unknown,
        additions: Int = 0,
        deletions: Int = 0,
        byteSize: Int? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.indexStatus = indexStatus
        self.workingTreeStatus = workingTreeStatus
        self.changeKind = changeKind
        self.contentKind = contentKind
        self.additions = additions
        self.deletions = deletions
        self.byteSize = byteSize
    }

    public var displayPath: String { path }
    public var hasStagedChanges: Bool { indexStatus != " " && indexStatus != "?" }
    public var hasUnstagedChanges: Bool { workingTreeStatus != " " && workingTreeStatus != "?" }
    public var isUntracked: Bool { indexStatus == "?" && workingTreeStatus == "?" }
    public var isMixed: Bool { hasStagedChanges && hasUnstagedChanges }
    public var statusBadge: String {
        if isUntracked { return "Untracked" }
        if isMixed { return "Mixed" }
        if hasStagedChanges { return "Staged" }
        if hasUnstagedChanges { return "Unstaged" }
        return "Changed"
    }
}

public struct ProjectFilePreview: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case unifiedDiff(String)
        case image(path: String, byteSize: Int?)
        case metadata(String)
        case tooLarge(byteSize: Int, limit: Int)
        case error(ProjectReviewError)
    }

    public var file: ProjectChangedFile
    public var content: Content

    public init(file: ProjectChangedFile, content: Content) {
        self.file = file
        self.content = content
    }
}

public final class ProjectReviewService: @unchecked Sendable {
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

    public static let fileLimit = 500
    public static let diffByteLimit = 200 * 1024
    private static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    private let runner: CommandRunner
    private let fileManager: FileManager

    public init(timeoutSeconds: TimeInterval = 3, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        runner = { cwd, arguments in
            await Self.runGitCommand(cwd: cwd, arguments: arguments, timeoutSeconds: timeoutSeconds)
        }
    }

    public init(runner: @escaping CommandRunner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func snapshot(cwd: String) async -> ProjectReviewSnapshot {
        let rootResult = await runner(cwd, ["rev-parse", "--show-toplevel"])
        guard rootResult.ok else { return failedSnapshot(rootResult, fallback: "Review is unavailable for this folder.") }
        let root = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return .unavailable("Review is unavailable for this folder.") }

        let statusResult = await runner(root, ["status", "--porcelain=v1", "--branch", "--untracked-files=all"])
        guard statusResult.ok else { return failedSnapshot(statusResult, fallback: "Git status could not be read.") }
        var header = ProjectGitStatusService.parsePorcelainStatus(statusResult.stdout)
        if header.isDetached {
            let detachedResult = await runner(root, ["rev-parse", "--short", "HEAD"])
            let shortSHA = detachedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if detachedResult.ok, !shortSHA.isEmpty {
                header.branch = shortSHA
            }
        }

        let headResult = await runner(root, ["rev-parse", "--verify", "HEAD"])
        let diffBase = headResult.ok ? "HEAD" : Self.emptyTreeHash
        let numstatResult = await runner(root, ["diff", "--numstat", diffBase, "--"])
        guard numstatResult.ok else { return failedSnapshot(numstatResult, fallback: "Git diff could not be read.") }
        let numstat = Self.parseNumstatByPath(numstatResult.stdout)

        let allFiles = Self.parseStatusFiles(statusResult.stdout)
            .map { enrich($0, root: root, numstat: numstat) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let visibleFiles = Array(allFiles.prefix(Self.fileLimit))

        return ProjectReviewSnapshot(
            isAvailable: true,
            root: root,
            branch: header.branch,
            isDetached: header.isDetached,
            files: visibleFiles,
            totalChangedFiles: allFiles.count,
            overflowCount: max(0, allFiles.count - visibleFiles.count)
        )
    }

    public func preview(cwd: String, file: ProjectChangedFile) async -> ProjectFilePreview {
        let root = await gitRoot(for: cwd) ?? cwd
        let absoluteURL = URL(fileURLWithPath: root).appendingPathComponent(file.path)
        if file.contentKind == .submodule {
            return .init(file: file, content: .metadata("Nested repositories and submodules are shown as metadata only."))
        }
        if file.contentKind == .image, file.changeKind != .deleted, fileManager.fileExists(atPath: absoluteURL.path) {
            return .init(file: file, content: .image(path: absoluteURL.path, byteSize: file.byteSize))
        }
        if file.contentKind == .binary {
            return .init(file: file, content: .metadata("Binary file preview is not supported."))
        }
        if let byteSize = file.byteSize, byteSize > Self.diffByteLimit {
            return .init(file: file, content: .tooLarge(byteSize: byteSize, limit: Self.diffByteLimit))
        }
        if file.isUntracked {
            return synthesizeUntrackedPreview(root: root, file: file, absoluteURL: absoluteURL)
        }

        let headResult = await runner(root, ["rev-parse", "--verify", "HEAD"])
        let diffBase = headResult.ok ? "HEAD" : Self.emptyTreeHash
        let result = await runner(root, ["diff", "--no-ext-diff", "--no-color", diffBase, "--", file.path])
        guard result.ok else {
            return .init(file: file, content: .error(reviewError(result, fallback: "Diff could not be loaded.")))
        }
        let diff = result.stdout
        if diff.utf8.count > Self.diffByteLimit {
            return .init(file: file, content: .tooLarge(byteSize: diff.utf8.count, limit: Self.diffByteLimit))
        }
        return .init(file: file, content: .unifiedDiff(diff.reviewNonEmpty ?? "No textual diff is available."))
    }

    private func gitRoot(for cwd: String) async -> String? {
        let rootResult = await runner(cwd, ["rev-parse", "--show-toplevel"])
        guard rootResult.ok else { return nil }
        let root = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    static func parseStatusFiles(_ output: String) -> [ProjectChangedFile] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("## ") && $0.count >= 3 }
            .compactMap { line -> ProjectChangedFile? in
                let indexStatus = line[line.startIndex]
                let workIndex = line.index(after: line.startIndex)
                let workingTreeStatus = line[workIndex]
                let rawPath = String(line.dropFirst(3))
                let oldPath: String?
                let path: String
                if (indexStatus == "R" || indexStatus == "C"), let range = rawPath.range(of: " -> ") {
                    oldPath = String(rawPath[..<range.lowerBound])
                    path = String(rawPath[range.upperBound...])
                } else {
                    oldPath = nil
                    path = rawPath
                }
                return ProjectChangedFile(
                    path: path,
                    oldPath: oldPath,
                    indexStatus: indexStatus,
                    workingTreeStatus: workingTreeStatus,
                    changeKind: changeKind(indexStatus: indexStatus, workingTreeStatus: workingTreeStatus)
                )
            }
    }

    static func parseNumstatByPath(_ output: String) -> [String: (additions: Int, deletions: Int, isBinary: Bool)] {
        output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { return }
            let path = String(columns.last ?? "")
            let isBinary = columns[0] == "-" || columns[1] == "-"
            result[path] = (
                additions: isBinary ? 0 : Int(columns[0]) ?? 0,
                deletions: isBinary ? 0 : Int(columns[1]) ?? 0,
                isBinary: isBinary
            )
        }
    }

    private func enrich(
        _ file: ProjectChangedFile,
        root: String,
        numstat: [String: (additions: Int, deletions: Int, isBinary: Bool)]
    ) -> ProjectChangedFile {
        let stats = numstat[file.path]
        let absolutePath = URL(fileURLWithPath: root).appendingPathComponent(file.path).path
        let attributes = (try? fileManager.attributesOfItem(atPath: absolutePath)) ?? [:]
        let fileType = attributes[.type] as? FileAttributeType
        let byteSize = (attributes[.size] as? NSNumber)?.intValue
        let contentKind: ProjectChangedFile.ContentKind
        if isNestedRepository(path: absolutePath, fileType: fileType) {
            contentKind = .submodule
        } else if fileType == .typeSymbolicLink {
            contentKind = .symlink
        } else if stats?.isBinary == true {
            contentKind = Self.isImagePath(file.path) ? .image : .binary
        } else if Self.isImagePath(file.path), file.changeKind != .deleted {
            contentKind = .image
        } else {
            contentKind = .text
        }
        return ProjectChangedFile(
            path: file.path,
            oldPath: file.oldPath,
            indexStatus: file.indexStatus,
            workingTreeStatus: file.workingTreeStatus,
            changeKind: file.changeKind,
            contentKind: contentKind,
            additions: stats?.additions ?? 0,
            deletions: stats?.deletions ?? 0,
            byteSize: byteSize
        )
    }

    private func synthesizeUntrackedPreview(root: String, file: ProjectChangedFile, absoluteURL: URL) -> ProjectFilePreview {
        if file.contentKind == .symlink {
            let target = (try? fileManager.destinationOfSymbolicLink(atPath: absoluteURL.path)) ?? ""
            let diff = """
            diff --git a/\(file.path) b/\(file.path)
            new file mode 120000
            --- /dev/null
            +++ b/\(file.path)
            @@ -0,0 +1 @@
            +\(target)
            """
            return .init(file: file, content: .unifiedDiff(diff))
        }
        guard let data = try? Data(contentsOf: absoluteURL, options: [.mappedIfSafe]) else {
            return .init(file: file, content: .error(.init(message: "File could not be read.")))
        }
        if data.count > Self.diffByteLimit {
            return .init(file: file, content: .tooLarge(byteSize: data.count, limit: Self.diffByteLimit))
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            return .init(file: file, content: .metadata("Binary file preview is not supported."))
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.map { "+\($0)" }.joined(separator: "\n")
        let diff = """
        diff --git a/\(file.path) b/\(file.path)
        new file mode 100644
        --- /dev/null
        +++ b/\(file.path)
        @@ -0,0 +1,\(max(lines.count, 1)) @@
        \(body)
        """
        return .init(file: file, content: .unifiedDiff(diff))
    }

    private func isNestedRepository(path: String, fileType: FileAttributeType?) -> Bool {
        guard fileType == .typeDirectory else { return false }
        return fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
    }

    private func failedSnapshot(_ result: GitCommandResult, fallback: String) -> ProjectReviewSnapshot {
        let error = reviewError(result, fallback: fallback)
        return .unavailable(error.message, rawOutput: error.rawOutput)
    }

    private func reviewError(_ result: GitCommandResult, fallback: String) -> ProjectReviewError {
        let raw = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return .init(message: raw.reviewNonEmpty ?? fallback, rawOutput: raw.reviewNonEmpty)
    }

    private static func changeKind(indexStatus: Character, workingTreeStatus: Character) -> ProjectChangedFile.ChangeKind {
        if indexStatus == "?" && workingTreeStatus == "?" { return .untracked }
        if indexStatus == "R" || workingTreeStatus == "R" { return .renamed }
        if indexStatus == "C" || workingTreeStatus == "C" { return .copied }
        if indexStatus == "D" || workingTreeStatus == "D" { return .deleted }
        if indexStatus == "A" || workingTreeStatus == "A" { return .added }
        if indexStatus == "T" || workingTreeStatus == "T" { return .typeChanged }
        if indexStatus == "M" || workingTreeStatus == "M" { return .modified }
        return .unknown
    }

    private static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func runGitCommand(
        cwd: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> GitCommandResult {
        await withCheckedContinuation { continuation in
            let resumeGate = ReviewResumeGate()

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

private final class ReviewResumeGate: @unchecked Sendable {
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
    var reviewNonEmpty: String? { isEmpty ? nil : self }
}
