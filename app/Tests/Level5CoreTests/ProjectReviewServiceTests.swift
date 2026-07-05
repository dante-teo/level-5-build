import Foundation
import Level5Core
import Testing

@Suite("Project review service")
struct ProjectReviewServiceTests {
    @Test("Parses staged unstaged mixed renames deletes and untracked rows")
    func parsesChangedRows() async {
        let service = ProjectReviewService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: true, stdout: "/repo\n", stderr: ""),
            "status --porcelain=v1 --branch --untracked-files=all": .init(ok: true, stdout: """
            ## feature/review
            M  staged.swift
             M unstaged.swift
            MM mixed.swift
            D  deleted.swift
            R  old.swift -> new.swift
            ?? scratch.md

            """, stderr: ""),
            "rev-parse --verify HEAD": .init(ok: true, stdout: "abc123\n", stderr: ""),
            "diff --numstat HEAD --": .init(ok: true, stdout: """
            2\t0\tstaged.swift
            1\t1\tunstaged.swift
            3\t2\tmixed.swift
            0\t4\tdeleted.swift
            5\t1\tnew.swift

            """, stderr: "")
        ]))

        let snapshot = await service.snapshot(cwd: "/repo")

        #expect(snapshot.isAvailable)
        #expect(snapshot.branch == "feature/review")
        #expect(snapshot.totalChangedFiles == 6)
        #expect(snapshot.files.first { $0.path == "staged.swift" }?.statusBadge == "Staged")
        #expect(snapshot.files.first { $0.path == "unstaged.swift" }?.statusBadge == "Unstaged")
        #expect(snapshot.files.first { $0.path == "mixed.swift" }?.statusBadge == "Mixed")
        #expect(snapshot.files.first { $0.path == "new.swift" }?.oldPath == "old.swift")
        #expect(snapshot.files.first { $0.path == "scratch.md" }?.changeKind == .untracked)
    }

    @Test("Caps rendered files at 500")
    func capsRenderedFiles() async {
        let statusRows = (0..<505).map { " M file-\($0).swift" }.joined(separator: "\n")
        let service = ProjectReviewService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: true, stdout: "/repo\n", stderr: ""),
            "status --porcelain=v1 --branch --untracked-files=all": .init(ok: true, stdout: "## main\n\(statusRows)\n", stderr: ""),
            "rev-parse --verify HEAD": .init(ok: true, stdout: "abc123\n", stderr: ""),
            "diff --numstat HEAD --": .init(ok: true, stdout: "", stderr: "")
        ]))

        let snapshot = await service.snapshot(cwd: "/repo")

        #expect(snapshot.files.count == 500)
        #expect(snapshot.totalChangedFiles == 505)
        #expect(snapshot.overflowCount == 5)
    }

    @Test("No commit repositories diff against empty tree")
    func noCommitRepositoryUsesEmptyTree() async {
        let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        let service = ProjectReviewService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: true, stdout: "/repo\n", stderr: ""),
            "status --porcelain=v1 --branch --untracked-files=all": .init(ok: true, stdout: "## No commits yet on main\nA  first.swift\n", stderr: ""),
            "rev-parse --verify HEAD": .init(ok: false, stdout: "", stderr: "fatal\n"),
            "diff --numstat \(emptyTree) --": .init(ok: true, stdout: "10\t0\tfirst.swift\n", stderr: "")
        ]))

        let snapshot = await service.snapshot(cwd: "/repo")

        #expect(snapshot.branch == "main")
        #expect(snapshot.files.first?.additions == 10)
    }

    @Test("Untracked text previews synthesize new file diffs and large files are deterministic")
    func untrackedPreviews() async throws {
        let root = try makeTemporaryDirectory()
        try "hello\nworld\n".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let large = String(repeating: "x", count: ProjectReviewService.diffByteLimit + 1)
        try large.write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let service = ProjectReviewService(runner: runner([:]))

        let notes = ProjectChangedFile(path: "notes.md", indexStatus: "?", workingTreeStatus: "?", changeKind: .untracked, contentKind: .text)
        let notesPreview = await service.preview(cwd: root.path, file: notes)
        let largeFile = ProjectChangedFile(path: "large.txt", indexStatus: "?", workingTreeStatus: "?", changeKind: .untracked, contentKind: .text, byteSize: ProjectReviewService.diffByteLimit + 1)
        let largePreview = await service.preview(cwd: root.path, file: largeFile)

        if case let .unifiedDiff(diff) = notesPreview.content {
            #expect(diff.contains("new file mode 100644"))
            #expect(diff.contains("+hello"))
        } else {
            Issue.record("Expected synthesized diff")
        }

        if case let .tooLarge(byteSize, limit) = largePreview.content {
            #expect(byteSize == ProjectReviewService.diffByteLimit + 1)
            #expect(limit == ProjectReviewService.diffByteLimit)
        } else {
            Issue.record("Expected large diff state")
        }
    }

    @Test("Status requests all untracked files so new directories expand")
    func statusRequestsAllUntrackedFiles() async {
        let service = ProjectReviewService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: true, stdout: "/repo\n", stderr: ""),
            "status --porcelain=v1 --branch --untracked-files=all": .init(ok: true, stdout: """
            ## main
            ?? dir/a.txt

            """, stderr: ""),
            "rev-parse --verify HEAD": .init(ok: true, stdout: "abc123\n", stderr: ""),
            "diff --numstat HEAD --": .init(ok: true, stdout: "", stderr: "")
        ]))

        let snapshot = await service.snapshot(cwd: "/repo")

        #expect(snapshot.files.map(\.path) == ["dir/a.txt"])
    }

    @Test("Previews resolve paths and diffs from the Git root")
    func previewsUseGitRootForSubdirectoryProjects() async {
        let commands = LockedCommands()
        let service = ProjectReviewService(runner: { cwd, arguments in
            commands.append("\(cwd): \(arguments.joined(separator: " "))")
            switch (cwd, arguments.joined(separator: " ")) {
            case ("/repo/app", "rev-parse --show-toplevel"):
                return .init(ok: true, stdout: "/repo\n", stderr: "")
            case ("/repo", "rev-parse --verify HEAD"):
                return .init(ok: true, stdout: "abc123\n", stderr: "")
            case ("/repo", "diff --no-ext-diff --no-color HEAD -- Sources/App.swift"):
                return .init(ok: true, stdout: "diff --git a/Sources/App.swift b/Sources/App.swift\n", stderr: "")
            default:
                return .init(ok: false, stdout: "", stderr: "unexpected command")
            }
        })
        let file = ProjectChangedFile(
            path: "Sources/App.swift",
            indexStatus: "M",
            workingTreeStatus: " ",
            changeKind: .modified,
            contentKind: .text
        )

        let preview = await service.preview(cwd: "/repo/app", file: file)

        if case let .unifiedDiff(diff) = preview.content {
            #expect(diff.contains("diff --git"))
        } else {
            Issue.record("Expected diff preview")
        }
        #expect(commands.values.contains("/repo: diff --no-ext-diff --no-color HEAD -- Sources/App.swift"))
    }

    @Test("Git failures surface friendly error with details")
    func gitFailures() async {
        let service = ProjectReviewService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: false, stdout: "", stderr: "fatal: not a git repository\n")
        ]))

        let snapshot = await service.snapshot(cwd: "/tmp/nope")

        #expect(snapshot.isAvailable == false)
        #expect(snapshot.error?.message == "fatal: not a git repository")
        #expect(snapshot.error?.rawOutput == "fatal: not a git repository")
    }

    private func runner(_ outputs: [String: ProjectReviewService.GitCommandResult]) -> ProjectReviewService.CommandRunner {
        { _, arguments in
            outputs[arguments.joined(separator: " ")]
                ?? .init(ok: false, stdout: "", stderr: "unexpected command: \(arguments.joined(separator: " "))")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("level5-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class LockedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ command: String) {
        lock.lock()
        storage.append(command)
        lock.unlock()
    }
}
