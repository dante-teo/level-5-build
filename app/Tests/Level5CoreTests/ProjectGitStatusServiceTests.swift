import Foundation
import Level5Core
import Testing

@Suite("Project git status service")
struct ProjectGitStatusServiceTests {
    @Test("Parses branch names with upstream suffixes")
    func parsesBranchNamesWithUpstreamSuffixes() async {
        let service = ProjectGitStatusService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: true, stdout: "/repo\n", stderr: ""),
            "status --porcelain=v1 --branch": .init(ok: true, stdout: "## feature/dashboard...origin/feature/dashboard\n M src/App.swift\n", stderr: ""),
            "rev-parse --verify HEAD": .init(ok: true, stdout: "abc123\n", stderr: ""),
            "diff --numstat HEAD --": .init(ok: true, stdout: "1\t2\tsrc/App.swift\n", stderr: "")
        ]))

        let status = await service.status(cwd: "/repo/app")

        #expect(status.branch == "feature/dashboard")
        #expect(status.changedFiles == 1)
        #expect(status.additions == 1)
        #expect(status.deletions == 2)
    }

    @Test("Replaces detached HEAD label with short SHA")
    func replacesDetachedHeadLabelWithShortSHA() async {
        let service = ProjectGitStatusService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: true, stdout: "/repo\n", stderr: ""),
            "status --porcelain=v1 --branch": .init(ok: true, stdout: "## HEAD (no branch)\n M src/App.swift\n", stderr: ""),
            "rev-parse --short HEAD": .init(ok: true, stdout: "abc1234\n", stderr: ""),
            "rev-parse --verify HEAD": .init(ok: true, stdout: "abc1234\n", stderr: ""),
            "diff --numstat HEAD --": .init(ok: true, stdout: "3\t1\tsrc/App.swift\n", stderr: "")
        ]))

        let status = await service.status(cwd: "/repo/app")

        #expect(status.branch == "abc1234")
        #expect(status.isDetached)
    }

    @Test("Parses no commits yet branch and diffs against empty tree")
    func parsesNoCommitsYetBranch() async {
        let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        let service = ProjectGitStatusService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: true, stdout: "/repo\n", stderr: ""),
            "status --porcelain=v1 --branch": .init(ok: true, stdout: "## No commits yet on main\nA  src/App.swift\n?? notes.md\n", stderr: ""),
            "rev-parse --verify HEAD": .init(ok: false, stdout: "", stderr: "fatal\n"),
            "diff --numstat \(emptyTree) --": .init(ok: true, stdout: "8\t0\tsrc/App.swift\n", stderr: "")
        ]))

        let status = await service.status(cwd: "/repo/app")

        #expect(status.branch == "main")
        #expect(status.changedFiles == 2)
        #expect(status.hasUntracked)
        #expect(status.additions == 8)
    }

    @Test("Sums numstat and ignores binary rows")
    func sumsNumstatAndIgnoresBinaryRows() async {
        let service = ProjectGitStatusService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: true, stdout: "/repo\n", stderr: ""),
            "status --porcelain=v1 --branch": .init(ok: true, stdout: "## main\n M a.swift\n M image.png\n?? notes.md\n", stderr: ""),
            "rev-parse --verify HEAD": .init(ok: true, stdout: "abc123\n", stderr: ""),
            "diff --numstat HEAD --": .init(ok: true, stdout: "12\t3\ta.swift\n-\t-\timage.png\n4\t0\tb.swift\n", stderr: "")
        ]))

        let status = await service.status(cwd: "/repo")

        #expect(status.changedFiles == 3)
        #expect(status.additions == 16)
        #expect(status.deletions == 3)
    }

    @Test("Non git directory returns unavailable")
    func nonGitDirectoryReturnsUnavailable() async {
        let service = ProjectGitStatusService(runner: runner([
            "rev-parse --show-toplevel": .init(ok: false, stdout: "", stderr: "fatal: not a git repository\n")
        ]))

        let status = await service.status(cwd: "/tmp/nope")

        #expect(status.isAvailable == false)
        #expect(status.error == "fatal: not a git repository")
    }

    @Test("Real fixture repository counts tracked and untracked changes")
    func realFixtureRepositoryCountsTrackedAndUntrackedChanges() async throws {
        let root = try makeTemporaryDirectory()
        try run("/usr/bin/git", ["init"], cwd: root)
        try write("first\n", to: root.appendingPathComponent("tracked.txt"))
        try run("/usr/bin/git", ["add", "tracked.txt"], cwd: root)
        try run("/usr/bin/git", ["-c", "user.email=test@example.com", "-c", "user.name=Tester", "commit", "-m", "initial"], cwd: root)
        try write("first\nsecond\n", to: root.appendingPathComponent("tracked.txt"))
        try write("scratch\n", to: root.appendingPathComponent("scratch.txt"))

        let status = await ProjectGitStatusService().status(cwd: root.path)

        #expect(status.isAvailable)
        #expect(status.changedFiles == 2)
        #expect(status.hasUntracked)
        #expect(status.additions == 1)
        #expect(status.deletions == 0)
    }

    private func runner(
        _ outputs: [String: ProjectGitStatusService.GitCommandResult]
    ) -> ProjectGitStatusService.CommandRunner {
        { _, arguments in
            outputs[arguments.joined(separator: " ")]
                ?? .init(ok: false, stdout: "", stderr: "unexpected command: \(arguments.joined(separator: " "))")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("level5-git-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(_ executable: String, _ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
