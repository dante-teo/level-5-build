import Foundation
import Testing
import Level5Core
@testable import Level5BuildApp

@Suite("Local shell model")
struct LocalShellModelTests {
    @Test("New chat clears local transcript and draft")
    func newChatClearsLocalState() {
        let project = RecentProject(
            path: "/tmp/level-5-build",
            displayName: "level-5-build",
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 0)
        )
        var model = LocalShellModel(
            draft: "unfinished",
            transcript: [
                LocalTranscriptItem(role: .user, text: "Hello")
            ],
            selectedProject: project
        )

        model.startNewChat()

        #expect(model.draft.isEmpty)
        #expect(model.transcript.isEmpty)
        #expect(model.selectedProject == project)
        #expect(model.isProjectSelectionAvailable)
    }

    @Test("Send ignores empty drafts")
    func sendIgnoresEmptyDrafts() {
        var model = LocalShellModel(draft: " \n\t ")

        let didSend = model.sendDraft()

        #expect(didSend == false)
        #expect(model.draft.isEmpty)
        #expect(model.transcript.isEmpty)
    }

    @Test("Send appends user and placeholder status items")
    func sendAppendsLocalTranscriptItems() {
        var model = LocalShellModel(draft: "Build the shell")

        let didSend = model.sendDraft()

        #expect(didSend)
        #expect(model.draft.isEmpty)
        #expect(model.transcript.map(\.role) == [.user, .status])
        #expect(model.transcript.first?.text == "Build the shell")
        #expect(model.transcript.last?.text == "Message captured.")
    }

    @Test("Agent text chunks merge into one transcript item")
    func agentTextChunksMerge() {
        var model = LocalShellModel()

        model.appendAgentText("Hello")
        model.appendAgentText(" world")

        #expect(model.transcript.map(\.role) == [.agent])
        #expect(model.transcript.first?.text == "Hello world")
    }

    @Test("Status updates stay separate transcript items")
    func statusUpdatesStaySeparate() {
        var model = LocalShellModel()

        model.appendStatus("Sending to ACP mock...")
        model.appendStatus("Plan: Inspect current state")

        #expect(model.transcript.map(\.role) == [.status, .status])
        #expect(model.transcript.map(\.text) == [
            "Sending to ACP mock...",
            "Plan: Inspect current state"
        ])
    }

    @Test("First send locks selected project context")
    func firstSendLocksSelectedProjectContext() {
        let project = RecentProject(
            path: "/tmp/level-5-build",
            displayName: "level-5-build",
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 0)
        )
        var model = LocalShellModel(draft: "Build the shell", selectedProject: project)

        let didSend = model.sendDraft()

        #expect(didSend)
        #expect(model.selectedProjectPath == "/tmp/level-5-build")
        #expect(model.isProjectSelectionAvailable == false)
    }

    @Test("Folderless send keeps selected project nil")
    func folderlessSendKeepsSelectedProjectNil() {
        var model = LocalShellModel(draft: "Build without a folder")

        let didSend = model.sendDraft()

        #expect(didSend)
        #expect(model.selectedProject == nil)
        #expect(model.selectedProjectPath == nil)
    }

    @Test("Selected project remains window local state")
    func selectedProjectIsNotRestoredByDefault() {
        let selected = RecentProject(
            path: "/tmp/level-5-build",
            displayName: "level-5-build",
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 0)
        )
        let modelWithSelection = LocalShellModel(selectedProject: selected)
        let freshModel = LocalShellModel()

        #expect(modelWithSelection.selectedProjectPath == "/tmp/level-5-build")
        #expect(freshModel.selectedProject == nil)
    }

    @Test("Clear transcript resets transcript state")
    func clearTranscriptResetsTranscriptState() {
        var model = LocalShellModel(
            draft: "kept",
            transcript: [
                LocalTranscriptItem(role: .user, text: "One"),
                LocalTranscriptItem(role: .status, text: "Two")
            ]
        )

        model.clearTranscript()

        #expect(model.draft == "kept")
        #expect(model.transcript.isEmpty)
    }

    @Test("Mock ACP runtime streams an agent response")
    @MainActor
    func mockAcpRuntimeStreamsAgentResponse() async throws {
        let repoRoot = try #require(findRepoRoot(), "Could not locate repository root")
        let mockRoot = repoRoot.appendingPathComponent("acp-mock-server", isDirectory: true)
        let startScript = mockRoot.appendingPathComponent("start.sh")
        guard FileManager.default.fileExists(atPath: startScript.path) else {
            print("Skipping mock runtime test: acp-mock-server/start.sh is missing")
            return
        }
        guard FileManager.default.fileExists(atPath: mockRoot.appendingPathComponent("node_modules").path) else {
            print("Skipping mock runtime test: acp-mock-server dependencies are not installed")
            return
        }
        guard FileManager.default.fileExists(atPath: mockRoot.appendingPathComponent("dist/src/index.js").path) else {
            print("Skipping mock runtime test: acp-mock-server dist output is not built")
            return
        }
        guard let nodePath = findExecutable("node") else {
            print("Skipping mock runtime test: node is not available")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Level5MockRuntimeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = MockAcpRuntime(environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
            "LEVEL5_USE_ACP_MOCK": "1",
            "LEVEL5_ACP_MOCK_START_PATH": startScript.path,
            "LEVEL5_NODE_PATH": nodePath,
            "ACP_MOCK_STATE_PATH": root.appendingPathComponent("state.json").path,
            "ACP_MOCK_DELAY_MS": "0",
            "ACP_MOCK_LOG": "silent"
        ], requestTimeoutSeconds: 5)
        var agentText = ""
        var statuses: [String] = []

        await runtime.send(
            prompt: "hello there",
            cwd: root.path,
            appendAgentText: { agentText += $0 },
            appendStatus: { statuses.append($0) }
        )
        runtime.reset()

        #expect(agentText.contains("ready to help"))
        #expect(statuses.contains("ACP mock turn ended: end_turn."))
    }

    @Test("Mock ACP runtime reset suppresses stale exit status")
    @MainActor
    func mockAcpRuntimeResetSuppressesStaleExitStatus() async throws {
        let repoRoot = try #require(findRepoRoot(), "Could not locate repository root")
        let mockRoot = repoRoot.appendingPathComponent("acp-mock-server", isDirectory: true)
        let startScript = mockRoot.appendingPathComponent("start.sh")
        guard FileManager.default.fileExists(atPath: startScript.path) else {
            print("Skipping mock runtime test: acp-mock-server/start.sh is missing")
            return
        }
        guard FileManager.default.fileExists(atPath: mockRoot.appendingPathComponent("node_modules").path) else {
            print("Skipping mock runtime test: acp-mock-server dependencies are not installed")
            return
        }
        guard FileManager.default.fileExists(atPath: mockRoot.appendingPathComponent("dist/src/index.js").path) else {
            print("Skipping mock runtime test: acp-mock-server dist output is not built")
            return
        }
        guard let nodePath = findExecutable("node") else {
            print("Skipping mock runtime test: node is not available")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Level5MockRuntimeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = MockAcpRuntime(environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
            "LEVEL5_USE_ACP_MOCK": "1",
            "LEVEL5_ACP_MOCK_START_PATH": startScript.path,
            "LEVEL5_NODE_PATH": nodePath,
            "ACP_MOCK_STATE_PATH": root.appendingPathComponent("state.json").path,
            "ACP_MOCK_DELAY_MS": "0",
            "ACP_MOCK_LOG": "silent"
        ], requestTimeoutSeconds: 5)
        var statuses: [String] = []

        await runtime.send(
            prompt: "hello there",
            cwd: root.path,
            appendAgentText: { _ in },
            appendStatus: { statuses.append($0) }
        )
        runtime.reset()
        let statusCountAfterReset = statuses.count

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(statuses.count == statusCountAfterReset)
        #expect(statuses.contains { $0.contains("ACP mock exited") } == false)
    }
}

private func findRepoRoot() -> URL? {
    var candidate = URL(fileURLWithPath: #filePath)
    for _ in 0..<8 {
        candidate.deleteLastPathComponent()
        let startScript = candidate
            .appendingPathComponent("acp-mock-server", isDirectory: true)
            .appendingPathComponent("start.sh")
        if FileManager.default.fileExists(atPath: startScript.path) {
            return candidate
        }
    }
    return nil
}

private func findExecutable(_ name: String) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", name]
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
