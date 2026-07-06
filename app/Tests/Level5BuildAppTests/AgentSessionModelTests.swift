import Foundation
import Level5Core
import Level5Design
import Testing
@testable import Level5BuildApp

@Suite("Agent session model", .serialized)
@MainActor
struct AgentSessionModelTests {
    @Test("Backend selector honors mock only when mock backends are allowed")
    func backendSelectorHonorsDebugGate() {
        let environment = ["LEVEL5_USE_ACP_MOCK": "1", "PATH": "/nonexistent"]

        #expect(AgentBackendSelector(environment: environment, allowsMockBackend: true, homeDirectoryPath: "/nonexistent-home").selectedBackend == .acpMock)
        #expect(AgentBackendSelector(environment: environment, allowsMockBackend: false, homeDirectoryPath: "/nonexistent-home").selectedBackend == .unavailable)
    }

    @Test("Default backend selector allows mock in debug builds")
    func defaultBackendSelectorAllowsMockInDebugBuilds() {
        let environment = ["LEVEL5_USE_ACP_MOCK": "1", "PATH": "/nonexistent"]
        #if DEBUG
        #expect(AgentBackendSelector(environment: environment, homeDirectoryPath: "/nonexistent-home").selectedBackend == .acpMock)
        #else
        #expect(AgentBackendSelector(environment: environment, homeDirectoryPath: "/nonexistent-home").selectedBackend == .unavailable)
        #endif
    }

    @Test("Backend selector picks Devin when the CLI resolves and mock is not requested")
    func backendSelectorPicksDevinWhenCliResolves() throws {
        let (binDirectory, environment) = try Self.makeFakeDevinInstall()
        defer { try? FileManager.default.removeItem(at: binDirectory.deletingLastPathComponent()) }

        let selector = AgentBackendSelector(environment: environment, allowsMockBackend: true, homeDirectoryPath: "/nonexistent-home")
        #expect(selector.selectedBackend == .devin)
        #expect(selector.unavailableReason == nil)
    }

    @Test("Backend selector reports unavailable reason when no CLI and no mock")
    func backendSelectorReportsUnavailableReason() {
        let selector = AgentBackendSelector(
            environment: ["PATH": "/nonexistent"],
            allowsMockBackend: false,
            homeDirectoryPath: "/nonexistent-home"
        )
        #expect(selector.selectedBackend == .unavailable)
        #expect(selector.unavailableReason == DevinRuntime.missingCliMessage)
    }

    @Test("Mock still wins over Devin when explicitly requested")
    func mockWinsOverDevinWhenRequested() throws {
        let (_, environment) = try Self.makeFakeDevinInstall(extra: ["LEVEL5_USE_ACP_MOCK": "1"])
        let selector = AgentBackendSelector(environment: environment, allowsMockBackend: true, homeDirectoryPath: "/nonexistent-home")
        #expect(selector.selectedBackend == .acpMock)
    }

    private static func makeFakeDevinInstall(extra: [String: String] = [:]) throws -> (binDirectory: URL, environment: [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executable = binDirectory.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var environment = extra
        environment["PATH"] = binDirectory.path
        return (binDirectory, environment)
    }

    @Test("No backend disables agent actions")
    func noBackendDisablesAgentActions() {
        let model = AgentSessionModel(
            backendKind: .unavailable,
            makeClient: { throw AgentBackendError.missingMockStartScript }
        )
        model.draft = "hello"

        #expect(model.availability.disablesAgentActions)
        #expect(model.canSendWithButton == false)
    }

    @Test("Missing Devin CLI surfaces the actionable install message, not a generic one")
    func missingDevinCliSurfacesActionableMessage() {
        let selector = AgentBackendSelector(
            environment: ["PATH": "/nonexistent"],
            allowsMockBackend: false,
            homeDirectoryPath: "/nonexistent-home"
        )
        let model = AgentSessionModel(selector: selector)

        guard case let .unavailable(message) = model.availability else {
            Issue.record("Expected .unavailable availability")
            return
        }
        #expect(message == DevinRuntime.missingCliMessage)
    }

    @Test("Review is available for selected project and caches loaded preview")
    func reviewAvailableForSelectedProjectAndCachesPreview() async throws {
        let previewCalls = LockedCounter()
        let file = ProjectChangedFile(path: "Sources/App.swift", indexStatus: "M", workingTreeStatus: " ", changeKind: .modified)
        let snapshot = ProjectReviewSnapshot(
            isAvailable: true,
            root: "/repo",
            branch: "main",
            files: [file],
            totalChangedFiles: 1
        )
        let model = AgentSessionModel(
            backendKind: .unavailable,
            makeClient: { throw AgentBackendError.missingMockStartScript },
            reviewSnapshotProvider: { _ in snapshot },
            reviewPreviewProvider: { _, file in
                previewCalls.increment()
                return ProjectFilePreview(file: file, content: .unifiedDiff("diff --git a/Sources/App.swift b/Sources/App.swift"))
            }
        )

        model.selectProject(.fixture(path: "/repo"))
        try await waitUntil { model.reviewState.changedFileCount == 1 }
        #expect(model.isReviewAvailable)
        #expect(model.reviewState.isOpen == false)

        model.openReview()
        model.loadReviewPreview(file)
        try await waitUntil { model.reviewState.previewCache[file.id] != nil }
        model.loadReviewPreview(file)
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.reviewState.isOpen)
        #expect(model.reviewState.previewCache[file.id]?.file == file)
        #expect(previewCalls.value == 1)
    }

    @Test("Review closes when selected project context is cleared")
    func reviewClosesWhenProjectContextChanges() async throws {
        let model = AgentSessionModel(
            backendKind: .unavailable,
            makeClient: { throw AgentBackendError.missingMockStartScript },
            reviewSnapshotProvider: { _ in
                ProjectReviewSnapshot(isAvailable: true, root: "/repo", branch: "main", files: [], totalChangedFiles: 0)
            }
        )

        model.selectProject(.fixture(path: "/repo"))
        model.openReview()
        try await waitUntil { model.reviewState.snapshot != nil }
        model.clearSelectedProject()

        #expect(model.isReviewAvailable == false)
        #expect(model.reviewState == ProjectReviewPaneState())
    }

    @Test("Failed first-send connection preserves draft and shows unavailable reason")
    func failedFirstSendConnectionPreservesDraft() async throws {
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { throw AgentBackendError.missingMockStartScript }
        )

        model.draft = "hello"
        model.sendDraft()
        try await waitUntil {
            if case .unavailable = model.availability { return true }
            return false
        }

        #expect(model.draft == "hello")
        if case let .unavailable(message) = model.availability {
            #expect(message.contains("Agent runtime unavailable"))
            #expect(message.contains("missingMockStartScript"))
        } else {
            Issue.record("Expected unavailable runtime")
        }
        #expect(model.activeSessionId == nil)
        #expect(model.transcript.isEmpty)
    }

    @Test("Default approval mode asks for approval")
    func defaultApprovalModeAsksForApproval() {
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { FakeAgentSessionClient() },
            approvalModePreferenceStore: .ephemeral
        )

        #expect(model.approvalMode == .ask)
    }

    @Test("Approval mode persists per backend")
    func approvalModePersistsPerBackend() {
        final class Box: @unchecked Sendable {
            var values: [AgentBackendKind: ApprovalMode] = [.acpMock: .fullAccess]
        }
        let box = Box()
        let store = ApprovalModePreferenceStore(
            load: { backend in box.values[backend] ?? .ask },
            save: { mode, backend in box.values[backend] = mode }
        )
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { FakeAgentSessionClient() },
            approvalModePreferenceStore: store
        )

        #expect(model.approvalMode == .fullAccess)
        model.selectApprovalMode(.approveForMe)

        let reloaded = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { FakeAgentSessionClient() },
            approvalModePreferenceStore: store
        )
        #expect(reloaded.approvalMode == .approveForMe)
    }

    @Test("Allow-like option detection normalizes labels and identifiers")
    func allowLikeOptionDetectionNormalizesValues() {
        #expect(PermissionOption(optionId: "allow-once", name: "Proceed", kind: nil).isAllowLike)
        #expect(PermissionOption(optionId: "tool_allow_once", name: "Proceed", kind: nil).isAllowLike)
        #expect(PermissionOption(optionId: "continue", name: "Always Allow", kind: nil).isAllowLike)
        #expect(PermissionOption(optionId: "continue", name: "Proceed", kind: "allow_once").isAllowLike)
        #expect(PermissionOption(optionId: "reject-once", name: "Reject", kind: nil).isAllowLike == false)
    }

    @Test("Startup discovery populates new chat model and slash commands without listing sessions")
    func startupDiscoveryPopulatesComposerState() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil { model.modelOptions.count == 2 && model.slashCommands.count == 2 }

        #expect(client.initializeCount == 1)
        #expect(model.draft.selectedModelId == "mock-pro")
        #expect(model.slashCommands.map(\.name) == ["plan", "review"])
        // There is no backend session discovery at all anymore (`AgentSessionClient`
        // doesn't even declare a `session/list` method): the sidebar is
        // sourced entirely from the durable local cache (see the "Startup
        // hydrates sidebar rows from persisted cache" test below).
        #expect(model.sessions.isEmpty)
    }

    @Test("New chat creates no session until first send")
    func newChatCreatesNoSessionUntilFirstSend() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.startNewChat()
        try await Task.sleep(for: .milliseconds(30))

        #expect(client.newSessionCwds.isEmpty)
        #expect(model.activeSessionId == nil)
        #expect(model.sessions.isEmpty)
    }

    @Test("First send creates a session and streams transcript text")
    func firstSendCreatesSessionAndStreamsTranscript() async throws {
        let client = FakeAgentSessionClient()
        client.newSessionResult = .init(sessionId: "s1")
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            homeDirectoryPath: "/Users/tester"
        )

        model.draft = "Build it"
        model.sendDraft()
        try await waitUntil { model.transcript.contains { $0.messageRole == .agent } }

        #expect(client.newSessionCwds == ["/Users/tester"])
        #expect(client.prompts.map(\.sessionId) == ["s1"])
        #expect(client.prompts.map(\.text) == ["Build it"])
        #expect(model.activeSessionId == "s1")
        #expect(model.sessions.map(\.sessionId) == ["s1"])
        #expect(model.transcript.first?.messageRole == .user)
        #expect(model.transcript.contains { $0.messageRole == .agent })
    }

    @Test("First send applies pending new chat model before prompting")
    func firstSendAppliesPendingModel() async throws {
        let client = FakeAgentSessionClient()
        client.newSessionResult = .init(sessionId: "s1", configOptions: [[
            "id": "model",
            "currentValue": "mock-pro",
            "options": [
                ["value": "mock-fast", "name": "Mock Fast"],
                ["value": "mock-pro", "name": "Mock Pro"]
            ]
        ]])
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil { model.modelOptions.count == 2 }
        model.selectModel("mock-fast")
        model.draft.appendText("Build it")
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }

        #expect(client.setModelRequestsSnapshot == [FakeAgentSessionClient.ModelRequest(sessionId: "s1", modelId: "mock-fast")])
    }

    @Test("Existing session model change rolls back on failure")
    func existingSessionModelChangeRollsBack() async throws {
        let client = FakeAgentSessionClient()
        client.setModelFailures = ["mock-fast"]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        // `selectModel` requires the target id already be in `modelOptions`,
        // which is populated by connection-time global discovery, not by
        // selecting a session (which never talks to the agent runtime).
        model.start()
        try await waitUntil { model.modelOptions.count == 2 }
        model.selectSession("s1")
        model.selectModel("mock-fast")
        try await waitUntil { model.runtimeMessage?.contains("Model change failed") == true }

        #expect(model.draft.selectedModelId == "mock-pro")
        #expect(client.setModelRequestsSnapshot == [FakeAgentSessionClient.ModelRequest(sessionId: "s1", modelId: "mock-fast")])
    }

    @Test("Existing session model change clears pending state when reconnect fails")
    func existingSessionModelChangeClearsPendingStateWhenReconnectFails() async throws {
        let client = FakeAgentSessionClient()
        let factory = FailingAfterFirstClientFactory(client)
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: factory.next)

        model.start()
        try await waitUntil { model.modelOptions.count == 2 }
        model.selectSession("s1")
        client.emitProcessExit()
        try await waitUntil { if case .disconnected = model.availability { true } else { false } }

        model.selectModel("mock-fast")
        try await waitUntil { model.sessionModelSaveInFlight == false }

        #expect(model.draft.selectedModelId == "mock-pro")
        #expect(client.setModelRequestsSnapshot.isEmpty)
    }

    @Test("Existing session model rollback is scoped after switching sessions")
    func existingSessionModelRollbackIsScopedAfterSwitchingSessions() async throws {
        let client = FakeAgentSessionClient()
        client.blocksSetModel = true
        client.setModelFailures = ["mock-fast"]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil { model.modelOptions.count == 2 }
        model.selectSession("s1")
        model.draft.appendText("s1 draft")
        model.selectModel("mock-fast")
        try await waitUntil { client.setModelRequestsSnapshot == [.init(sessionId: "s1", modelId: "mock-fast")] }

        model.selectSession("s2")
        model.draft.selectedModelId = "mock-fast"
        client.releaseSetModel()
        try await waitUntil { model.runtimeMessage?.contains("Model change failed") == true }

        #expect(model.activeSessionId == "s2")
        #expect(model.draft.selectedModelId == "mock-fast")

        model.selectSession("s1")
        #expect(model.draft.selectedModelId == "mock-pro")
        #expect(model.draft.plainText == "s1 draft")
    }

    @Test("Sending text with command and attachment emits ACP prompt blocks")
    func sendingStructuredComposerEmitsPromptBlocks() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.draft.appendText("Please")
        model.acceptSlashCommand(.init(name: "plan"))
        model.draft.appendText("this")
        model.addAttachments(urls: [URL(fileURLWithPath: "/tmp/spec.md")], kind: .file)
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }

        #expect(client.prompts.first?.text == "Please /plan this")
        #expect(client.prompts.first?.blocks == [
            [
                "type": "text",
                "text": "Please /plan this"
            ],
            [
                "type": "resource_link",
                "uri": "file:///tmp/spec.md",
                "name": "spec.md"
            ]
        ])
        #expect(model.draft.isEmpty)
    }

    @Test("Optimistic user echo suppresses chunked backend user replay")
    func optimisticUserEchoSuppressesChunkedBackendUserReplay() async throws {
        let client = FakeAgentSessionClient()
        client.userEchoChunksByPrompt["Build it"] = ["Build", " it"]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.draft = "Build it"
        model.sendDraft()
        try await waitUntil { model.transcript.contains { $0.messageRole == .agent } }

        #expect(model.transcript.userMessageTexts == ["Build it"])
    }

    @Test("Selecting a session never talks to the agent runtime; sending primes it first and its replay never repaints the transcript")
    func sendingPrimesUnprimedSessionBeforePromptingAndSuppressesItsReplay() async throws {
        let client = FakeAgentSessionClient()
        client.loadReplay["s1"] = [
            .messageChunk(role: .user, messageId: "u1", text: "Previous prompt"),
            .messageChunk(role: .agent, messageId: "a1", text: "Previous answer")
        ]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        #expect(client.loadedSessionIds.isEmpty)
        #expect(model.transcript.isEmpty)

        model.draft = "Next prompt"
        model.sendDraft()
        try await waitUntil { client.prompts.contains { $0.text == "Next prompt" } }

        #expect(client.loadedSessionIds == ["s1"])
        #expect(client.prompts.last?.sessionId == "s1")
        // The prime's replay is a context-loading side effect, never a way
        // to repaint the transcript: only the live send's own content shows.
        #expect(model.transcript.contains { $0.messageText == "Previous prompt" } == false)
        #expect(model.transcript.contains { $0.messageText == "Previous answer" } == false)
        #expect(model.transcript.userMessageTexts == ["Next prompt"])
    }

    @Test("Composer drafts are scoped per selected session")
    func composerDraftsAreScopedPerSession() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.draft.appendText("draft one")

        model.selectSession("s2")
        #expect(model.draft.serializedText.isEmpty)
        model.draft.appendText("draft two")

        model.selectSession("s1")
        #expect(model.draft.serializedText == "draft one")

        model.selectSession("s2")
        #expect(model.draft.serializedText == "draft two")
    }

    @Test("Selecting a session does not change sidebar recency order")
    func selectingSessionDoesNotChangeSidebarOrder() async throws {
        let fixture = try PersistenceFixture()
        try fixture.store.upsertSessionRow(.init(
            sessionId: "older",
            projectKey: PersistenceFixture.sharedProjectKey,
            backend: "mock",
            title: "Older",
            detail: "d",
            observedAt: 1,
            createdAt: 1
        ))
        try fixture.store.upsertSessionRow(.init(
            sessionId: "newer",
            projectKey: PersistenceFixture.sharedProjectKey,
            backend: "mock",
            title: "Newer",
            detail: "d",
            observedAt: 2,
            createdAt: 2
        ))
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client }, persistenceStore: fixture.store)

        model.start()
        #expect(model.sessions.map(\.sessionId) == ["newer", "older"])

        model.selectSession("older")
        #expect(model.sessions.map(\.sessionId) == ["newer", "older"])

        model.draft = "new work"
        model.sendDraft()
        try await waitUntil("older prompted") { client.promptSessionIds == ["older"] }
        try await waitUntil("older moved first") { model.sessions.map(\.sessionId) == ["older", "newer"] }
    }

    @Test("Live message after selecting a session updates sidebar recency")
    func liveMessageAfterSelectingSessionUpdatesSidebarOrder() async throws {
        let fixture = try PersistenceFixture()
        try fixture.store.upsertSessionRow(.init(
            sessionId: "older",
            projectKey: PersistenceFixture.sharedProjectKey,
            backend: "mock",
            title: "Older",
            detail: "d",
            observedAt: 1,
            createdAt: 1
        ))
        try fixture.store.upsertSessionRow(.init(
            sessionId: "newer",
            projectKey: PersistenceFixture.sharedProjectKey,
            backend: "mock",
            title: "Newer",
            detail: "d",
            observedAt: 2,
            createdAt: 2
        ))
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client }, persistenceStore: fixture.store)

        model.start()
        model.selectSession("older")
        #expect(model.sessions.map(\.sessionId) == ["newer", "older"])

        // The shared mock client only starts consuming events once
        // connected; `start()` already connects it for the home project key.
        try await waitUntil { client.initializeCount == 1 }
        client.emitAgentText("older", "live response")

        try await waitUntil("older moved first after live message") {
            model.sessions.map(\.sessionId) == ["older", "newer"]
        }
    }

    @Test("Transcript follow-tail state is tracked per session")
    func transcriptFollowTailStateIsPerSession() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        #expect(model.activeTranscriptFollowsTail)
        model.setActiveTranscriptFollowsTail(false)
        #expect(model.activeTranscriptFollowsTail == false)

        model.selectSession("s2")
        #expect(model.activeTranscriptFollowsTail)

        model.selectSession("s1")
        #expect(model.activeTranscriptFollowsTail == false)
    }

    @Test("Sending respects manual scroll-away follow-tail state")
    func sendingRespectsManualScrollAwayFollowTailState() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.setActiveTranscriptFollowsTail(false)

        model.draft = "do not jump"
        model.sendDraft()
        try await waitUntil("prompt sent") { client.promptSessionIds == ["s1"] }

        #expect(model.activeTranscriptFollowsTail == false)
    }

    @Test("Failed prompt clears pending optimistic user echo")
    func failedPromptClearsPendingOptimisticUserEcho() async throws {
        let client = FakeAgentSessionClient()
        client.failBeforeUserEchoPrompts = ["first"]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")

        model.draft = "first"
        model.sendDraft()
        try await waitUntil("first failed") {
            model.transcript.contains { $0.errorText?.contains("Prompt failed") == true }
        }

        model.draft = "second"
        model.sendDraft()
        try await waitUntil("second response") {
            model.transcript.contains { $0.messageText == "response second" }
        }

        #expect(model.transcript.userMessageTexts == ["first", "second"])
    }

    @Test("Concurrent sessions route streamed updates by session id")
    func concurrentSessionsRouteUpdatesBySessionId() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.draft = "one"
        model.sendDraft()
        try await waitUntil("prompted s1") { client.promptSessionIds == ["s1"] }

        model.selectSession("s2")
        model.draft = "two"
        model.sendDraft()
        try await waitUntil("prompted s2") { client.promptSessionIds == ["s1", "s2"] }

        try await waitUntil("active s2 transcript") { model.transcript.first?.messageText == "two" }

        model.selectSession("s1")
        try await waitUntil("active s1 transcript") { model.transcript.first?.messageText == "one" }
    }

    @Test("Active plan and usage are scoped to selected session")
    func activePlanAndUsageAreScopedToSelectedSession() async throws {
        // Plan/usage are session metadata driven purely by live updates now
        // (never by a selection-time replay), so inject them directly.
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil { client.initializeCount == 1 }

        model.selectSession("s1")
        client.emitTranscriptEvent(.plan(entries: [.init(id: "p1", content: "Session one plan", status: "in_progress", priority: "high")]), sessionId: "s1")
        client.emitTranscriptEvent(.usage(.init(used: 10, size: 100, amount: nil, currency: nil)), sessionId: "s1")
        try await waitUntil { model.activePlan?.entries.first?.content == "Session one plan" }
        try await waitUntil { model.activeUsage?.used == 10 }

        model.selectSession("s2")
        client.emitTranscriptEvent(.plan(entries: [.init(id: "p2", content: "Session two plan", status: "completed", priority: "high")]), sessionId: "s2")
        client.emitTranscriptEvent(.usage(.init(used: 70, size: 100, amount: 0.02, currency: "USD")), sessionId: "s2")
        try await waitUntil { model.activePlan?.entries.first?.content == "Session two plan" }
        try await waitUntil { model.activeUsage?.used == 70 }

        model.selectSession("s1")
        #expect(model.activePlan?.entries.first?.content == "Session one plan")
        #expect(model.activeUsage?.used == 10)
    }

    @Test("Completed plan clears when next prompt starts")
    func completedPlanClearsWhenNextPromptStarts() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil { client.initializeCount == 1 }
        model.selectSession("s1")
        client.emitTranscriptEvent(.plan(entries: [.init(id: "p1", content: "Done plan", status: "completed", priority: "high")]), sessionId: "s1")
        try await waitUntil { model.activePlan?.isComplete == true }

        model.draft = "next"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        #expect(model.activePlan == nil)
    }

    @Test("Same-session sends queue FIFO and queued prompts can be removed")
    func sameSessionQueueIsFIFOAndRemovable() async throws {
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        client.newSessionResult = .init(sessionId: "s1")
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.draft = "first"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        model.draft = "second"
        model.sendDraft()
        model.draft = "third"
        model.sendDraft()
        try await waitUntil { model.activeQueue.count == 2 }
        #expect(model.transcript.userMessageTexts == ["first"])

        model.removeQueuedPrompt(model.activeQueue[1])
        #expect(model.activeQueue.map(\.text) == ["second"])

        client.releaseNextPrompt()
        try await waitUntil { client.prompts.count == 2 }
        #expect(client.prompts.map(\.text) == ["first", "second"])
        #expect(model.transcript.userMessageTexts == ["first", "second"])
        client.releaseNextPrompt()
        try await waitUntil { model.isActiveSessionRunning == false }
    }

    @Test("Failed queued prompt continues to later queue entries")
    func failedQueuedPromptContinuesQueue() async throws {
        let client = FakeAgentSessionClient()
        client.promptFailures = ["second"]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        model.draft = "second"
        model.sendDraft()
        model.draft = "third"
        model.sendDraft()
        try await waitUntil { client.prompts.map(\.text) == ["first", "second", "third"] }

        #expect(model.transcript.contains { $0.errorText?.contains("Prompt failed") == true })
    }

    @Test("Stop cancels active turn and clears same-session queue")
    func stopCancelsActiveTurnAndClearsQueue() async throws {
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 && model.isActiveSessionRunning }
        model.draft = "queued"
        model.sendDraft()
        try await waitUntil { model.activeQueue.map(\.text) == ["queued"] }

        model.cancelActiveTurn()
        try await waitUntil { client.cancelledSessionIdsSnapshot == ["s1"] }

        #expect(model.isActiveSessionRunning == false)
        #expect(model.activeQueue.isEmpty)
        #expect(model.canEditComposer)

        client.releaseNextPrompt()
    }

    @Test("Stop cancels pending permission and suppresses late output")
    func stopCancelsPendingPermissionAndSuppressesLateOutput() async throws {
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        client.emitAgentText("s1", "already streamed")
        client.emitPermissionRequest(id: .int(44), sessionId: "s1")
        try await waitUntil { model.activePermissionRequest != nil }

        model.cancelActiveTurn()
        try await waitUntil { client.cancelledPermissionRequestIdsSnapshot == [.int(44)] }
        client.emitAgentText("s1", "late output")
        client.releaseNextPrompt()
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.activePermissionRequest == nil)
        #expect(model.canEditComposer)
        #expect(model.transcript.contains { $0.messageText == "already streamed" })
        #expect(model.transcript.contains { $0.messageText == "late output" } == false)
    }

    @Test("New prompt after Stop reuses selected session")
    func newPromptAfterStopUsesSelectedSession() async throws {
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        model.cancelActiveTurn()
        try await waitUntil { model.isActiveSessionRunning == false }
        client.releaseNextPrompt()

        client.blocksPrompts = false
        model.draft = "after stop"
        model.sendDraft()
        try await waitUntil { client.prompts.map(\.text).contains("after stop") }

        #expect(model.activeSessionId == "s1")
        #expect(client.prompts.last?.sessionId == "s1")
    }

    @Test("Stop suppression survives immediate re-prompt until new prompt echo")
    func stopSuppressionSurvivesImmediateRepromptUntilNewPromptEcho() async throws {
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        model.cancelActiveTurn()
        try await waitUntil { model.isActiveSessionRunning == false }

        client.blockBeforeUserEchoPrompts = ["after stop"]
        client.blocksPrompts = false
        model.draft = "after stop"
        model.sendDraft()
        try await waitUntil { client.prompts.map(\.text) == ["first", "after stop"] }
        client.emitAgentText("s1", "late cancelled output")
        client.releaseNextUserEcho()
        try await waitUntil { model.transcript.contains { $0.messageText == "response after stop" } }

        #expect(model.transcript.contains { $0.messageText == "late cancelled output" } == false)
        #expect(client.prompts.last?.sessionId == "s1")

        client.releaseNextPrompt()
    }

    @Test("Cancel failure disconnects and next action reconnects")
    func cancelFailureDisconnectsAndNextActionReconnects() async throws {
        let first = FakeAgentSessionClient()
        first.blocksPrompts = true
        first.cancelFailures = ["s1"]
        let second = FakeAgentSessionClient()
        let factory = FakeClientFactory([first, second])
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { factory.next() })

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        try await waitUntil { first.prompts.count == 1 }
        model.cancelActiveTurn()
        try await waitUntil {
            if case .disconnected = model.availability { return true }
            return false
        }

        first.releaseNextPrompt()
        model.draft = "after reconnect"
        model.sendDraft()
        try await waitUntil { second.prompts.count == 1 }

        #expect(second.initializeCount == 1)
        #expect(second.prompts.first?.sessionId == "s1")
    }

    @Test("Idle timeout cancels, resets runtime, and reconnects on next action")
    func idleTimeoutCancelsResetsAndReconnects() async throws {
        let first = FakeAgentSessionClient()
        first.blocksPrompts = true
        let second = FakeAgentSessionClient()
        let factory = FakeClientFactory([first, second])
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { factory.next() },
            turnIdleTimeoutMilliseconds: 30
        )

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        try await waitUntil { first.prompts.count == 1 }
        try await waitUntil(timeout: .seconds(1)) {
            if case .disconnected = model.availability { return true }
            return false
        }

        #expect(first.cancelledSessionIdsSnapshot == ["s1"])
        #expect(model.isActiveSessionRunning == false)
        #expect(model.activePermissionRequest == nil)
        #expect(model.transcript.contains { $0.errorText?.contains("idle") == true })

        first.releaseNextPrompt()
        model.draft = "after timeout"
        model.sendDraft()
        try await waitUntil { second.prompts.count == 1 }

        #expect(second.initializeCount == 1)
        #expect(second.prompts.first?.sessionId == "s1")
    }

    @Test("Pending human permission pauses idle watchdog")
    func pendingHumanPermissionPausesIdleWatchdog() async throws {
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral,
            turnIdleTimeoutMilliseconds: 1_000
        )

        model.selectSession("s1")
        model.draft = "needs approval"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        client.emitPermissionRequest(id: .int(55), sessionId: "s1")
        try await waitUntil { model.activePermissionRequest != nil }
        try await Task.sleep(for: .milliseconds(120))

        #expect(client.cancelledSessionIdsSnapshot.isEmpty)
        #expect(model.isActiveSessionRunning)

        model.cancelActiveTurn()
        client.releaseNextPrompt()
    }

    @Test("Ask approval stores active pending request and blocks composer")
    func askApprovalStoresActivePendingRequestAndBlocksComposer() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        // Selecting a session never connects the runtime on its own, so
        // connect explicitly to give the permission notification below
        // somewhere to be delivered to.
        model.start()
        try await waitUntil { client.initializeCount == 1 }
        model.selectSession("s1")
        client.emitPermissionRequest(id: .int(12), sessionId: "s1")
        try await waitUntil { model.activePermissionRequest?.sessionId == "s1" }

        #expect(model.canEditComposer == false)
        #expect(model.canSendWithButton == false)
        #expect(model.sessions.first(where: { $0.sessionId == "s1" })?.isAwaitingPermission == true)
    }

    @Test("Choosing permission option sends selected ACP response")
    func choosingPermissionOptionSendsSelectedACPResponse() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.start()
        try await waitUntil { client.initializeCount == 1 }
        model.selectSession("s1")
        client.emitPermissionRequest(id: .int(12), sessionId: "s1")
        try await waitUntil { model.activePermissionRequest != nil }

        model.respondToPermission(optionId: "allow-always")
        try await waitUntil {
            client.permissionResponsesSnapshot.count == 1
                && model.activePermissionRequest == nil
        }

        #expect(client.permissionResponsesSnapshot == [.init(
            requestId: .int(12),
            optionId: "allow-always",
            localInstructionText: nil
        )])
        #expect(model.activePermissionRequest == nil)
        #expect(model.canEditComposer)
    }

    @Test("Failed permission response clears takeover and restores composer")
    func failedPermissionResponseClearsTakeoverAndRestoresComposer() async throws {
        let client = FakeAgentSessionClient()
        client.permissionResponseFailures = [.int(12)]
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.start()
        try await waitUntil { client.initializeCount == 1 }
        model.selectSession("s1")
        client.emitPermissionRequest(id: .int(12), sessionId: "s1")
        try await waitUntil { model.activePermissionRequest != nil }

        model.respondToPermission(optionId: "allow-once")
        try await waitUntil { model.runtimeMessage?.contains("Permission response failed") == true }

        #expect(model.activePermissionRequest == nil)
        #expect(model.canEditComposer)
    }

    @Test("Background session permission does not block current session")
    func backgroundSessionPermissionDoesNotBlockCurrentSession() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.start()
        try await waitUntil { client.initializeCount == 1 }
        model.selectSession("s1")
        client.emitPermissionRequest(id: .int(22), sessionId: "s2")
        try await waitUntil {
            model.sessions.first(where: { $0.sessionId == "s2" })?.isAwaitingPermission == true
        }

        #expect(model.activeSessionId == "s1")
        #expect(model.activePermissionRequest == nil)
        #expect(model.canEditComposer)
    }

    @Test("Approve for me auto-approves mock permission silently")
    func approveForMeAutoApprovesMockPermissionSilently() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.selectApprovalMode(.approveForMe)
        model.start()
        try await waitUntil { client.initializeCount == 1 }
        model.selectSession("s1")
        client.emitPermissionRequest(id: .int(12), sessionId: "s1")
        try await waitUntil { client.permissionResponsesSnapshot.count == 1 }

        #expect(client.permissionResponsesSnapshot.first?.optionId == "allow-once")
        #expect(model.activePermissionRequest == nil)
        #expect(model.transcript.contains { $0.statusText?.contains("Approve for me") == true } == false)
    }

    @Test("Full access auto-approves silently")
    func fullAccessAutoApprovesSilently() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.selectApprovalMode(.fullAccess)
        model.start()
        try await waitUntil { client.initializeCount == 1 }
        model.selectSession("s1")
        client.emitPermissionRequest(id: .int(12), sessionId: "s1")
        try await waitUntil { client.permissionResponsesSnapshot.count == 1 }

        #expect(client.permissionResponsesSnapshot.first?.optionId == "allow-once")
        #expect(model.transcript.contains { $0.statusText?.contains("Approve for me") == true } == false)
    }

    @Test("Automatic approval falls back to first option")
    func automaticApprovalFallsBackToFirstOption() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.selectApprovalMode(.fullAccess)
        model.start()
        try await waitUntil { client.initializeCount == 1 }
        model.selectSession("s1")
        client.emitPermissionRequest(
            id: .int(12),
            sessionId: "s1",
            options: [
                ["optionId": "continue", "name": "Continue", "kind": "continue"],
                ["optionId": "stop", "name": "Stop", "kind": "stop"]
            ]
        )
        try await waitUntil { client.permissionResponsesSnapshot.count == 1 }

        #expect(client.permissionResponsesSnapshot.first?.optionId == "continue")
    }

    @Test("Reject with instructions responds with reject option and queues follow-up")
    func rejectWithInstructionsRespondsAndQueuesFollowUp() async throws {
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        client.emitPermissionRequest(id: .int(12), sessionId: "s1")
        try await waitUntil { model.activePermissionRequest != nil }

        model.rejectPermissionWithInstructions("Try a safer edit")
        try await waitUntil { client.permissionResponsesSnapshot.count == 1 && model.activeQueue.count == 1 }

        #expect(client.permissionResponsesSnapshot.first == .init(
            requestId: .int(12),
            optionId: "reject-once",
            localInstructionText: "Try a safer edit"
        ))
        #expect(model.activeQueue.map(\.text) == ["Try a safer edit"])

        client.releaseNextPrompt()
        try await waitUntil { client.prompts.map(\.text) == ["first", "Try a safer edit"] }
        client.releaseNextPrompt()
    }

    @Test("Delete removes the session locally and clears active deleted session")
    func deleteRefreshesAndClearsActiveSession() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.deleteSession("s1")
        try await waitUntil { client.deletedSessionIds == ["s1"] && model.sessions.isEmpty }

        #expect(model.activeSessionId == nil)
    }

    @Test("Deleting a session removes it locally even when the backend's session/delete fails, and it stays hidden from later live updates")
    func deleteSucceedsLocallyDespiteBackendDeleteFailureAndStaysHidden() async throws {
        // Mirrors the real Devin gap: `session/delete` is unimplemented
        // ("Method not found"). Our local sidebar is not required to stay
        // consistent with the backend's — once deleted here, it must stay
        // gone regardless of what the backend still reports.
        let client = FakeAgentSessionClient()
        client.deleteSessionFailures = ["s1"]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.deleteSession("s1")

        try await waitUntil { client.deletedSessionIds == ["s1"] && model.sessions.isEmpty }
        #expect(model.sessions.isEmpty)
        #expect(model.activeSessionId == nil)

        // A later background update for the "deleted" session must not
        // resurrect it in the sidebar.
        client.emitSessionInfoUpdate("s1", title: "Resurrected?")
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.sessions.isEmpty)
    }

    @Test("Successful end turn marks sidebar completion until next activity")
    func successfulEndTurnMarksCompletionUntilNextActivity() async throws {
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        model.draft = "first"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        client.releaseNextPrompt()
        try await waitUntil { model.sessions.first(where: { $0.sessionId == "s1" })?.hasCompletedTurn == true }

        model.draft = "second"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 2 }
        #expect(model.sessions.first(where: { $0.sessionId == "s1" })?.hasCompletedTurn == false)

        client.releaseNextPrompt()
    }

    @Test("Process exit marks runtime disconnected and reconnects on next action")
    func processExitDisconnectsAndNextActionReconnects() async throws {
        let first = FakeAgentSessionClient()
        first.exitOnPrompts = ["exit now"]
        let second = FakeAgentSessionClient()
        second.newSessionResult = .init(sessionId: "s2")
        let factory = FakeClientFactory([first, second])
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { factory.next() })

        model.draft = "exit now"
        model.sendDraft()
        try await waitUntil("first runtime disconnected") {
            if case .disconnected = model.availability { return true }
            return false
        }

        model.draft = "after exit"
        model.sendDraft()
        try await waitUntil("second runtime prompted") { second.prompts.count == 1 }

        #expect(second.initializeCount == 1)
        #expect(second.prompts.first?.sessionId == "s1")
    }

    @Test("Explicit selected project creates project-backed session and home fallback does not")
    func projectBackedEligibilityForNewSessions() async throws {
        let client = FakeAgentSessionClient()
        let project = RecentProject(
            path: "/Users/tester/Project",
            displayName: "Project",
            createdAt: .distantPast,
            lastOpenedAt: .distantPast
        )
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            gitStatusProvider: { _ in .unavailable() },
            homeDirectoryPath: "/Users/tester"
        )

        model.setRecentProjects([project])
        model.selectProject(project)
        model.draft = "Build it"
        model.sendDraft()
        try await waitUntil { model.activeSessionId == "s1" }

        #expect(model.activeSessionProjectPath == "/Users/tester/Project")
        #expect(model.dashboardState?.projectPath == "/Users/tester/Project")

        model.startNewChat()
        model.clearSelectedProject()
        client.newSessionResult = .init(sessionId: "s2")
        model.draft = "Home task"
        model.sendDraft()
        try await waitUntil { model.activeSessionId == "s2" }

        #expect(client.newSessionCwds == ["/Users/tester/Project", "/Users/tester"])
        #expect(model.activeSessionProjectPath == nil)
        #expect(model.dashboardState == nil)
    }

    @Test("Dashboard refresh ignores stale git result after switching project-backed sessions")
    func dashboardRefreshIgnoresStaleResults() async throws {
        actor Gate {
            var continuations: [CheckedContinuation<ProjectGitStatus, Never>] = []
            func wait() async -> ProjectGitStatus {
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                }
            }
            func release(_ status: ProjectGitStatus) {
                continuations.removeFirst().resume(returning: status)
            }
        }
        let gate = Gate()
        let client = FakeAgentSessionClient()
        // Keep turns open so sending doesn't also trigger `send`'s own
        // post-turn dashboard refresh, which would add extra untracked
        // `gitStatusProvider` calls beyond the two this test releases.
        client.blocksPrompts = true
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            gitStatusProvider: { _ in await gate.wait() }
        )
        let projectOne = RecentProject(path: "/repo/one", displayName: "one", createdAt: .distantPast, lastOpenedAt: .distantPast)
        let projectTwo = RecentProject(path: "/repo/two", displayName: "two", createdAt: .distantPast, lastOpenedAt: .distantPast)
        model.setRecentProjects([projectOne, projectTwo])

        client.newSessionResult = .init(sessionId: "one")
        model.selectProject(projectOne)
        model.draft = "hello"
        model.sendDraft()
        try await waitUntil("one dashboard") { model.dashboardState?.projectPath == "/repo/one" }

        model.startNewChat()
        client.newSessionResult = .init(sessionId: "two")
        model.selectProject(projectTwo)
        model.draft = "hello"
        model.sendDraft()
        try await waitUntil("two dashboard") { model.dashboardState?.projectPath == "/repo/two" }

        // `selectProject` also kicks off its own `gitStatusProvider` call to
        // refresh `selectedProjectBranch`, ahead of session creation and
        // `beginTurn`'s own dashboard refreshes, so switching sessions after
        // both sends leaves 6 pending `gitStatusProvider` calls in flight (1
        // for `selectProject` + 2 per session, all blocked on
        // `client.blocksPrompts` before either turn's own completion could
        // trigger yet another). Only the *last* dashboard one for the
        // currently active project (project two) should win; the two
        // `selectProject` releases are consumed but their value is
        // irrelevant since they only feed `selectedProjectBranch`.
        await gate.release(.unavailable())
        await gate.release(.init(isAvailable: true, root: "/repo/one", branch: "stale", changedFiles: 99))
        await gate.release(.init(isAvailable: true, root: "/repo/one", branch: "stale", changedFiles: 99))
        await gate.release(.unavailable())
        await gate.release(.init(isAvailable: true, root: "/repo/two", branch: "stale", changedFiles: 99))
        await gate.release(.init(isAvailable: true, root: "/repo/two", branch: "main", changedFiles: 1))
        try await waitUntil { model.dashboardState?.gitStatus.branch == "main" }

        #expect(model.dashboardState?.projectPath == "/repo/two")
        #expect(model.dashboardState?.gitStatus.changedFiles == 1)

        client.releaseNextPrompt()
        client.releaseNextPrompt()
    }

    @Test("References include web and external files but exclude in-project files")
    func referencesFilterAndDedupe() async throws {
        // References are session metadata driven purely by live updates
        // now (never by a send-time priming replay), so inject them
        // directly once a project-backed session is actually running.
        let client = FakeAgentSessionClient()
        client.blocksPrompts = true
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            gitStatusProvider: { _ in .unavailable() }
        )
        let project = RecentProject(path: "/repo/project", displayName: "project", createdAt: .distantPast, lastOpenedAt: .distantPast)
        model.setRecentProjects([project])

        model.selectProject(project)
        model.draft = "Build it"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }
        let sessionId = try #require(model.activeSessionId)

        client.emitTranscriptEvent(.references([
            .init(kind: .web, title: "Docs", uri: "https://example.com/docs"),
            .init(kind: .web, title: "Duplicate Docs", uri: "https://example.com/docs"),
            .init(kind: .file, title: "External", uri: URL(fileURLWithPath: "/tmp/external.md").absoluteString),
            .init(kind: .file, title: "Duplicate External", uri: URL(fileURLWithPath: "/tmp/external.md").absoluteString),
            .init(kind: .file, title: "Internal", uri: URL(fileURLWithPath: "/repo/project/Sources/App.swift").absoluteString)
        ]), sessionId: sessionId)
        try await waitUntil { model.dashboardState?.references.count == 2 }

        #expect(model.dashboardState?.references.map(\.uri) == [
            "https://example.com/docs",
            URL(fileURLWithPath: "/tmp/external.md").absoluteString
        ])
        #expect(Set(model.dashboardState?.references.map(\.id) ?? []).count == 2)

        client.releaseNextPrompt()
    }

    @Test("Adaptive dashboard policy follows width fallback and compact overlay")
    func adaptiveDashboardPolicy() {
        var state = ProjectDashboardAdaptiveState()

        state.update(horizontalSizeClass: nil, workspaceWidth: L5Spacing.x16 * 17)
        #expect(state.presentation == .reserved)

        state.update(horizontalSizeClass: nil, workspaceWidth: L5Spacing.x16 * 8)
        #expect(state.presentation == .hidden)

        state.toggle()
        #expect(state.presentation == .overlay)

        state.update(horizontalSizeClass: nil, workspaceWidth: L5Spacing.x16 * 8)
        #expect(state.presentation == .hidden)

        state.toggle()
        #expect(state.presentation == .overlay)

        state.update(horizontalSizeClass: nil, workspaceWidth: L5Spacing.x16 * 17)
        #expect(state.presentation == .reserved)

        state.close()
        #expect(state.presentation == .hidden)
        state.toggle()
        #expect(state.presentation == .reserved)
    }

    // MARK: - Devin multi-project isolation

    @Test("Two projects get independent Devin clients spawned with that project's cwd")
    func multiProjectClientsSpawnPerProject() async throws {
        let clientA = FakeAgentSessionClient()
        clientA.newSessionResult = .init(sessionId: "a1")
        let clientB = FakeAgentSessionClient()
        clientB.newSessionResult = .init(sessionId: "b1")
        let clientsByPath = [
            RecentProjectStore.normalizedPath("/repo/project-a"): clientA,
            RecentProjectStore.normalizedPath("/repo/project-b"): clientB
        ]
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard let client = clientsByPath[cwd] else { throw AgentBackendError.missingDevinExecutable }
                return client
            },
            gitStatusProvider: { _ in .unavailable() }
        )
        let projectA = RecentProject(path: "/repo/project-a", displayName: "a", createdAt: .distantPast, lastOpenedAt: .distantPast)
        let projectB = RecentProject(path: "/repo/project-b", displayName: "b", createdAt: .distantPast, lastOpenedAt: .distantPast)

        // Selecting a project eagerly connects and silently primes a
        // session for the composer (models/slash-commands); wait for that
        // to land before sending so the send path reuses it rather than
        // racing a second `session/new`.
        model.selectProject(projectA)
        try await waitUntil { clientA.newSessionCwds == ["/repo/project-a"] }
        model.draft = "hello a"
        model.sendDraft()
        try await waitUntil { clientA.prompts.count == 1 }

        model.startNewChat()
        model.selectProject(projectB)
        try await waitUntil { clientB.newSessionCwds == ["/repo/project-b"] }
        model.draft = "hello b"
        model.sendDraft()
        try await waitUntil { clientB.prompts.count == 1 }

        // Exactly one `session/new` per project: the priming call is reused
        // as the real session rather than creating a second one.
        #expect(clientA.newSessionCwds == ["/repo/project-a"])
        #expect(clientB.newSessionCwds == ["/repo/project-b"])
        #expect(clientA.prompts.map(\.text) == ["hello a"])
        #expect(clientB.prompts.map(\.text) == ["hello b"])
        #expect(clientA.initializeCount == 1)
        #expect(clientB.initializeCount == 1)
    }

    @Test("Sending into an already-restored session waits for start()'s composer priming instead of racing it")
    func sendingIntoRestoredSessionWaitsForStartupPriming() async throws {
        let fixture = try PersistenceFixture()
        let homePath = RecentProjectStore.normalizedPath("/Users/tester")
        try fixture.store.upsertSessionRow(.init(
            sessionId: "s1",
            projectKey: homePath,
            backend: "devin",
            title: "Home session",
            detail: "d",
            createdAt: 1
        ))

        let client = FakeAgentSessionClient()
        client.newSessionResult = .init(sessionId: "primed")
        // Simulates real Devin's slow startup (team settings fetch, MCP
        // server connections) taking a few real seconds before its
        // composer-priming `session/new` actually resolves.
        client.blocksNewSession = true
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { _, _ in client },
            persistenceStore: fixture.store,
            gitStatusProvider: { _ in .unavailable() },
            homeDirectoryPath: "/Users/tester"
        )

        // `start()` eagerly connects and primes the home-directory composer
        // in the background — exactly like a real app launch. Wait only
        // until that priming's `session/new` has actually been *entered*
        // (not resolved — it's blocked) before acting, mirroring a real
        // user who selects an old session and sends while app-launch's
        // eager composer-priming is still in flight. Without sequencing
        // against it, this would fire `session/load` + `session/prompt`
        // concurrently with the still in-flight `session/new`, which real
        // Devin's ACP server does not handle safely (see
        // `AgentSessionModel.awaitComposerPriming`).
        model.start()
        try await waitUntil("composer priming has started") {
            !client.newSessionCwds.isEmpty
        }
        model.selectSession("s1")
        model.draft = "continue please"
        model.sendDraft()

        // Give the (non-priming) parts of the send path a moment to run;
        // it must still be waiting on the blocked `session/new`, not
        // already racing ahead into `session/load`/`session/prompt`.
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.loadedSessionIds.isEmpty)
        #expect(client.promptSessionIds.isEmpty)

        client.releaseNewSession()

        try await waitUntil("reconnect proceeds only after priming settles") {
            client.promptSessionIds == ["s1"]
        }
        #expect(client.loadedSessionIds == ["s1"])
    }

    @Test("One project's process exit does not disrupt another project's active turn")
    func multiProjectProcessExitIsIsolated() async throws {
        let clientA = FakeAgentSessionClient()
        clientA.newSessionResult = .init(sessionId: "a1")
        clientA.blocksPrompts = true
        let clientB = FakeAgentSessionClient()
        clientB.newSessionResult = .init(sessionId: "b1")
        let clientsByPath = [
            RecentProjectStore.normalizedPath("/repo/project-a"): clientA,
            RecentProjectStore.normalizedPath("/repo/project-b"): clientB
        ]
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard let client = clientsByPath[cwd] else { throw AgentBackendError.missingDevinExecutable }
                return client
            },
            gitStatusProvider: { _ in .unavailable() }
        )
        let projectA = RecentProject(path: "/repo/project-a", displayName: "a", createdAt: .distantPast, lastOpenedAt: .distantPast)
        let projectB = RecentProject(path: "/repo/project-b", displayName: "b", createdAt: .distantPast, lastOpenedAt: .distantPast)

        model.selectProject(projectA)
        try await waitUntil { clientA.newSessionCwds == ["/repo/project-a"] }
        model.draft = "hello a"
        model.sendDraft()
        try await waitUntil { clientA.prompts.count == 1 }
        let sessionAId = try #require(model.activeSessionId)

        model.startNewChat()
        model.selectProject(projectB)
        try await waitUntil { clientB.newSessionCwds == ["/repo/project-b"] }
        model.draft = "hello b"
        model.sendDraft()
        try await waitUntil { model.activeSessionId == "b1" }

        clientB.emitProcessExit()
        try await waitUntil { if case .disconnected = model.availability { true } else { false } }

        // Project A's turn (on a separate, still-healthy process) keeps running.
        #expect(model.sessions.first { $0.sessionId == sessionAId }?.isRunning == true)

        clientA.releaseNextPrompt()
        try await waitUntil { model.sessions.first { $0.sessionId == sessionAId }?.isRunning == false }
    }

    @Test("The sidebar shows every project's persisted sessions at once, regardless of which project is selected")
    func sidebarShowsEveryProjectsSessionsRegardlessOfSelection() async throws {
        let fixture = try PersistenceFixture()
        let pathA = RecentProjectStore.normalizedPath("/repo/project-a")
        let pathB = RecentProjectStore.normalizedPath("/repo/project-b")
        try fixture.store.upsertSessionRow(.init(sessionId: "a1", projectKey: pathA, backend: "devin", title: "A session", detail: "d", createdAt: 1))
        try fixture.store.upsertSessionRow(.init(sessionId: "b1", projectKey: pathB, backend: "devin", title: "B session", detail: "d", createdAt: 1))
        let clientA = FakeAgentSessionClient()
        let clientB = FakeAgentSessionClient()
        let clientsByPath = [pathA: clientA, pathB: clientB]
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard let client = clientsByPath[cwd] else { throw AgentBackendError.missingDevinExecutable }
                return client
            },
            persistenceStore: fixture.store,
            gitStatusProvider: { _ in .unavailable() }
        )
        let projectA = RecentProject(path: "/repo/project-a", displayName: "a", createdAt: .distantPast, lastOpenedAt: .distantPast)
        let projectB = RecentProject(path: "/repo/project-b", displayName: "b", createdAt: .distantPast, lastOpenedAt: .distantPast)

        // Neither project has been selected yet; the sidebar is still a
        // global list, not scoped to the (currently unset) composer
        // project.
        model.start()
        #expect(Set(model.sessions.map(\.sessionId)) == ["a1", "b1"])

        // Selecting A (or B) only changes where the *next* new chat would
        // be created; it must not evict the other project's row, since
        // with true multi-project concurrency that project's process (and
        // any work happening there) is still alive.
        model.selectProject(projectA)
        #expect(Set(model.sessions.map(\.sessionId)) == ["a1", "b1"])

        model.selectProject(projectB)
        #expect(Set(model.sessions.map(\.sessionId)) == ["a1", "b1"])
    }

    @Test("A persisted session becomes project-backed once recents catch up, even if hydration raced ahead of them")
    func hydratedSessionBecomesProjectBackedAfterRecentsCatchUp() throws {
        // Mirrors `ContentView.selectProject(_ url:)`, which calls
        // `model.selectProject` (hydrating synchronously) before its own
        // `loadRecentProjects()`/`model.setRecentProjects` call resolves.
        // `recentProjectPaths` must not need to already contain the project
        // at the moment of hydration for its persisted sessions to still be
        // recognized as project-backed once recents do catch up.
        let fixture = try PersistenceFixture()
        let pathA = RecentProjectStore.normalizedPath("/repo/project-a")
        try fixture.store.upsertSessionRow(.init(sessionId: "a1", projectKey: pathA, backend: "devin", title: "A session", detail: "d", createdAt: 1))
        let clientA = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard cwd == pathA else { throw AgentBackendError.missingDevinExecutable }
                return clientA
            },
            persistenceStore: fixture.store,
            gitStatusProvider: { _ in .unavailable() }
        )
        let projectA = RecentProject(path: "/repo/project-a", displayName: "a", createdAt: .distantPast, lastOpenedAt: .distantPast)

        // Hydrate with `recentProjectPaths` still empty (the race window).
        model.selectProject(projectA)
        model.selectSession("a1")
        #expect(model.activeSessionProjectPath == nil)

        // Recents catch up moments later, as they do right after
        // `ContentView.selectProject(_ url:)`'s own `loadRecentProjects()`.
        model.setRecentProjects([projectA])
        model.selectSession("a1")
        #expect(model.activeSessionProjectPath == "/repo/project-a")
    }

    @Test("A background project's idle-timeout cancellation does not clobber the foreground project's status")
    func backgroundProjectIdleTimeoutDoesNotLeakIntoForegroundStatus() async throws {
        let clientA = FakeAgentSessionClient()
        clientA.newSessionResult = .init(sessionId: "a1")
        let clientB = FakeAgentSessionClient()
        clientB.newSessionResult = .init(sessionId: "b1")
        clientB.blocksPrompts = true
        let clientsByPath = [
            RecentProjectStore.normalizedPath("/repo/project-a"): clientA,
            RecentProjectStore.normalizedPath("/repo/project-b"): clientB
        ]
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard let client = clientsByPath[cwd] else { throw AgentBackendError.missingDevinExecutable }
                return client
            },
            gitStatusProvider: { _ in .unavailable() },
            turnIdleTimeoutMilliseconds: 30
        )
        let projectA = RecentProject(path: "/repo/project-a", displayName: "a", createdAt: .distantPast, lastOpenedAt: .distantPast)
        let projectB = RecentProject(path: "/repo/project-b", displayName: "b", createdAt: .distantPast, lastOpenedAt: .distantPast)

        model.selectProject(projectA)
        try await waitUntil { clientA.initializeCount == 1 }

        // Start a turn on project B (background), then switch focus back to
        // A before B's turn idle-times-out.
        model.startNewChat()
        model.selectProject(projectB)
        try await waitUntil { clientB.initializeCount == 1 }
        model.draft = "hello b"
        model.sendDraft()
        try await waitUntil { clientB.prompts.count == 1 }

        model.startNewChat()
        model.selectProject(projectA)
        try await waitUntil { model.availability == .available }

        // Give B's watchdog time to fire its idle timeout in the background.
        try await Task.sleep(for: .milliseconds(120))

        // A is healthy and in the foreground: its status must not be
        // clobbered by B's background idle-timeout disconnect.
        #expect(model.availability == .available)
        #expect(model.runtimeMessage == nil)

        clientB.releaseNextPrompt()
    }

    @Test("Starting up eagerly connects and primes the home-directory composer with real models")
    func startPrimesHomeComposerEagerly() async throws {
        let client = FakeAgentSessionClient()
        client.newSessionResult = .init(sessionId: "home1", configOptions: [[
            "id": "model",
            "currentValue": "real-model",
            "options": [["value": "real-model", "name": "Real Model"]]
        ]])
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { _, _ in client },
            gitStatusProvider: { _ in .unavailable() },
            homeDirectoryPath: "/Users/tester"
        )

        model.start()

        // The composer should already reflect a real model before the user
        // has typed or sent anything.
        try await waitUntil { model.modelOptions.map(\.id) == ["real-model"] }
        #expect(client.newSessionCwds == ["/Users/tester"])
        #expect(model.activeSessionId == nil)
        #expect(model.sessions.isEmpty)
    }

    @Test("Selecting a project eagerly primes that project's composer, independent of home")
    func selectingProjectPrimesItsOwnComposerEagerly() async throws {
        let homeClient = FakeAgentSessionClient()
        homeClient.newSessionResult = .init(sessionId: "home1", configOptions: [[
            "id": "model",
            "currentValue": "home-model",
            "options": [["value": "home-model", "name": "Home Model"]]
        ]])
        let projectClient = FakeAgentSessionClient()
        projectClient.newSessionResult = .init(sessionId: "proj1", configOptions: [[
            "id": "model",
            "currentValue": "project-model",
            "options": [["value": "project-model", "name": "Project Model"]]
        ]])
        let clientsByPath = [
            RecentProjectStore.normalizedPath("/Users/tester"): homeClient,
            RecentProjectStore.normalizedPath("/repo/project"): projectClient
        ]
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard let client = clientsByPath[cwd] else { throw AgentBackendError.missingDevinExecutable }
                return client
            },
            gitStatusProvider: { _ in .unavailable() },
            homeDirectoryPath: "/Users/tester"
        )

        model.start()
        try await waitUntil { model.modelOptions.map(\.id) == ["home-model"] }

        let project = RecentProject(path: "/repo/project", displayName: "project", createdAt: .distantPast, lastOpenedAt: .distantPast)
        model.selectProject(project)
        try await waitUntil { model.modelOptions.map(\.id) == ["project-model"] }

        #expect(projectClient.newSessionCwds == ["/repo/project"])
        #expect(model.activeSessionId == nil)
    }

    @Test("loadSession request includes mcpServers, which real Devin requires or rejects the call")
    func loadSessionIncludesMcpServers() async throws {
        final class LineCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var _lines: [String] = []
            var lines: [String] { lock.withLock { _lines } }
            func record(_ line: String) { lock.withLock { _lines.append(line) } }
        }
        struct TestClient: AcpClientBackedSessionClient {
            let client: AcpClient

            func listModelOptions(sessionId: String?) async throws -> (options: [ComposerModelOption], currentModelId: String?) {
                ([], nil)
            }

            func listSlashCommands(sessionId: String?) async throws -> [ComposerCommand] { [] }

            func terminate() {}
        }

        let capture = LineCapture()
        let transport = AcpJsonRpcTransport(requestTimeout: .seconds(2)) { line in
            capture.record(line)
        }
        let testClient = TestClient(client: AcpClient(transport: transport))

        let resultTask = Task { try await testClient.loadSession(sessionId: "abc", cwd: nil) }
        try await waitUntil { capture.lines.count == 1 }

        let line = capture.lines[0]
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(json?["method"] as? String == "session/load")
        let params = json?["params"] as? [String: Any]
        #expect(params?["mcpServers"] != nil)

        let id = json?["id"] as? Int ?? -1
        await transport.handleLine(#"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"abc"}}"#)
        let result = try await resultTask.value
        #expect(result.sessionId == "abc")
    }

    @Test("Slash commands and skills from a live update survive a backend with no discovery API")
    func slashCommandsSurviveThrowingDiscoveryClient() async throws {
        let client = FakeAgentSessionClient()
        client.throwsOnDiscovery = true
        client.newSessionResult = .init(sessionId: "s1")
        // Real Devin has no request/response API for slash commands or
        // skills; they only arrive as an `available_commands_update`
        // notification that streams in *before* the session/new RPC
        // response, the way the real ACP wire order behaves.
        client.availableCommandNamesOnNewSession = ["grill-me", "code-review", "find-skills"]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.draft = "Build it"
        model.sendDraft()
        try await waitUntil { client.prompts.count == 1 }

        // A backend client whose `listSlashCommands`/`listModelOptions`
        // throw (rather than succeeding with an empty list) must not let
        // those calls wipe out what the notification already populated.
        #expect(model.slashCommands.map(\.name) == ["grill-me", "code-review", "find-skills"])
    }

    // MARK: - Durable session/transcript persistence

    @Test("Startup hydrates sidebar rows from persisted cache; there is no session/list to overwrite them")
    func sidebarShowsPersistedRowsBeforeSessionListResolves() throws {
        let fixture = try PersistenceFixture()
        try fixture.store.upsertSessionRow(.init(
            sessionId: "cached-1",
            projectKey: PersistenceFixture.sharedProjectKey,
            backend: "mock",
            title: "Cached session",
            detail: "cached detail",
            observedAt: 10,
            createdAt: 5
        ))
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client }, persistenceStore: fixture.store)

        model.start()

        // Checked synchronously, before any `await`: proves the sidebar is
        // populated from disk alone, with no dependency on `ensureConnected`
        // (async) ever resolving.
        #expect(model.sessions.map(\.sessionId) == ["cached-1"])
        #expect(model.sessions.first?.title == "Cached session")
    }

    @Test("Selecting a session paints its cached transcript and never touches it again just by looking")
    func selectingSessionPaintsCacheAndLeavesItUntouched() async throws {
        let fixture = try PersistenceFixture()
        try fixture.store.upsertSessionRow(.init(
            sessionId: "s1",
            projectKey: PersistenceFixture.sharedProjectKey,
            backend: "mock",
            title: "t",
            detail: "d",
            createdAt: 1
        ))
        let cachedItem = AgentTranscriptItem(id: "message-cached", kind: .message(.init(role: .agent, messageId: "cached", text: "cached content")))
        let persisted = try #require(TranscriptPersistenceCoding.encode(cachedItem))
        try fixture.store.upsertTranscriptItems(sessionId: "s1", items: [persisted])

        let client = FakeAgentSessionClient()
        client.loadReplay["s1"] = [.messageChunk(role: .agent, messageId: "live", text: "live content")]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client }, persistenceStore: fixture.store)

        model.selectSession("s1")

        // Cache paints immediately, synchronously — selection never talks
        // to the agent runtime at all.
        #expect(model.transcript.map(\.messageText) == ["cached content"])
        #expect(client.loadedSessionIds.isEmpty)

        try await Task.sleep(for: .milliseconds(30))
        #expect(model.transcript.map(\.messageText) == ["cached content"])
        #expect(client.loadedSessionIds.isEmpty)
    }

    @Test("Deleting a session removes its persisted rows")
    func deletingSessionRemovesPersistedRows() async throws {
        let fixture = try PersistenceFixture()
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client }, persistenceStore: fixture.store)

        model.selectSession("s1")
        #expect(try fixture.store.listAllSessionRows().map(\.sessionId) == ["s1"])

        model.deleteSession("s1")

        try await waitUntil("session row removed") {
            (try? fixture.store.listAllSessionRows().isEmpty) == true
        }
    }

    @Test("A corrupt persisted transcript payload doesn't crash and is treated as a cache miss")
    func corruptPersistedTranscriptPayloadIsCacheMiss() throws {
        let fixture = try PersistenceFixture()
        try fixture.store.upsertSessionRow(.init(
            sessionId: "s1",
            projectKey: PersistenceFixture.sharedProjectKey,
            backend: "mock",
            title: "t",
            detail: "d",
            createdAt: 1
        ))
        let goodItem = AgentTranscriptItem(id: "message-good", kind: .message(.init(role: .agent, messageId: "good", text: "good content")))
        let goodPersisted = try #require(TranscriptPersistenceCoding.encode(goodItem))
        let corruptPersisted = PersistedTranscriptItem(itemId: "message-bad", kind: "message", payloadVersion: 1, payload: Data("not valid json".utf8))
        try fixture.store.upsertTranscriptItems(sessionId: "s1", items: [goodPersisted, corruptPersisted])

        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client }, persistenceStore: fixture.store)

        model.selectSession("s1")

        #expect(model.transcript.map(\.messageText) == ["good content"])
    }

    @Test("A relaunch restores sessions and transcript content persisted by an earlier launch")
    func relaunchRestoresPersistedSessionsAndTranscript() async throws {
        let fixture = try PersistenceFixture()

        let client1 = FakeAgentSessionClient()
        let model1 = AgentSessionModel(backendKind: .acpMock, makeClient: { client1 }, persistenceStore: fixture.store)
        model1.selectSession("s1")
        model1.draft = "hello there"
        model1.sendDraft()
        try await waitUntil("turn completed") {
            model1.transcript.contains { $0.messageText == "response hello there" }
        }
        try await waitUntil("transcript persisted") {
            (try? fixture.store.fetchTranscriptItems(sessionId: "s1").isEmpty) == false
        }

        // Simulate a fresh launch: a second model instance, with no
        // in-memory state of its own, sharing only the on-disk store.
        let client2 = FakeAgentSessionClient()
        let model2 = AgentSessionModel(backendKind: .acpMock, makeClient: { client2 }, persistenceStore: fixture.store)

        model2.start()
        #expect(model2.sessions.map(\.sessionId) == ["s1"])

        model2.selectSession("s1")
        #expect(model2.transcript.map(\.messageText).contains("response hello there"))
        #expect(model2.transcript.contains { $0.messageRole == .user })
    }

    @Test("Sending into a relaunch-restored session after a failed reconnect leaves the composer usable, not stuck")
    func relaunchSendFailureLeavesComposerUsable() async throws {
        let fixture = try PersistenceFixture()

        let client1 = FakeAgentSessionClient()
        let model1 = AgentSessionModel(backendKind: .acpMock, makeClient: { client1 }, persistenceStore: fixture.store)
        model1.selectSession("s1")
        model1.draft = "hello there"
        model1.sendDraft()
        try await waitUntil("turn completed") {
            model1.transcript.contains { $0.messageText == "response hello there" }
        }

        // Simulate a fresh launch: a second model instance/process, whose
        // client has no live context for "s1" and fails to reconnect to it
        // (e.g. the real backend has no in-memory record of the session in
        // this brand-new process).
        let client2 = FakeAgentSessionClient()
        client2.loadSessionFailures.insert("s1")
        let model2 = AgentSessionModel(backendKind: .acpMock, makeClient: { client2 }, persistenceStore: fixture.store)

        model2.start()
        // Let the initial connect settle before sending, so the send's own
        // (already-connected, no-op) `ensureConnected` call can't coincide
        // with — and be masked by — the connect-succeeded handler's own
        // unconditional `runtimeMessage = nil`.
        try await waitUntil("initial connect settled") { model2.availability == .available }
        model2.selectSession("s1")
        model2.draft = "continue please"
        model2.sendDraft()

        try await waitUntil("load failure surfaced") {
            model2.transcript.contains { $0.errorText?.contains("Failed to load session") == true }
        }

        // The composer must not be left showing a stale "starting/sending"
        // hint, nor stuck thinking a turn is still running, once the
        // failure has been surfaced.
        #expect(model2.runtimeMessage == nil)
        #expect(model2.isActiveSessionRunning == false)

        // A retry (e.g. once the backend/connection recovers) must still
        // be possible rather than being permanently wedged.
        client2.loadSessionFailures.remove("s1")
        model2.draft = "continue please"
        model2.sendDraft()
        try await waitUntil("retry succeeded") {
            client2.promptSessionIds.contains("s1")
        }
        #expect(model2.runtimeMessage == nil)
    }

    @Test("Reconnect priming a Devin session after a relaunch includes cwd, which real Devin requires or rejects the call")
    func relaunchReconnectPrimingIncludesCwd() async throws {
        let fixture = try PersistenceFixture()
        let projectPath = RecentProjectStore.normalizedPath("/repo/project-a")

        let client1 = FakeAgentSessionClient()
        client1.newSessionResult = .init(sessionId: "s1")
        let model1 = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard cwd == projectPath else { throw AgentBackendError.missingDevinExecutable }
                return client1
            },
            persistenceStore: fixture.store,
            gitStatusProvider: { _ in .unavailable() }
        )
        let project = RecentProject(path: "/repo/project-a", displayName: "a", createdAt: .distantPast, lastOpenedAt: .distantPast)
        model1.selectProject(project)
        try await waitUntil { client1.newSessionCwds == [projectPath] }
        model1.draft = "hello there"
        model1.sendDraft()
        try await waitUntil("turn completed") { client1.promptSessionIds == ["s1"] }

        // Simulate a fresh launch/process: a new client with no live
        // context for "s1", reconnecting to the same project directory.
        let client2 = FakeAgentSessionClient()
        let model2 = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard cwd == projectPath else { throw AgentBackendError.missingDevinExecutable }
                return client2
            },
            persistenceStore: fixture.store,
            gitStatusProvider: { _ in .unavailable() }
        )
        model2.start()
        model2.selectSession("s1")
        model2.draft = "continue please"
        model2.sendDraft()

        try await waitUntil("reconnect primed and prompt sent") { client2.promptSessionIds == ["s1"] }
        #expect(client2.loadSessionCwdsSnapshot == [projectPath])

        // Sending successfully isn't enough on its own: the agent's reply
        // streams back as live `session/update` events over this
        // reconnected client's own event stream, routed by client
        // generation — it must actually reach the transcript, not just the
        // outgoing prompt land.
        try await waitUntil("agent reply reached the transcript") {
            model2.transcript.contains { $0.messageText == "response continue please" }
        }
    }

    @Test("Preparing for app termination closes every open session across every project before terminating its client")
    func prepareForTerminationClosesOpenSessionsAcrossProjects() async throws {
        let clientA = FakeAgentSessionClient()
        clientA.newSessionResult = .init(sessionId: "a1")
        let clientB = FakeAgentSessionClient()
        clientB.newSessionResult = .init(sessionId: "b1")
        let clientsByPath = [
            RecentProjectStore.normalizedPath("/repo/project-a"): clientA,
            RecentProjectStore.normalizedPath("/repo/project-b"): clientB
        ]
        let model = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, _ in
                guard let client = clientsByPath[cwd] else { throw AgentBackendError.missingDevinExecutable }
                return client
            },
            gitStatusProvider: { _ in .unavailable() }
        )
        let projectA = RecentProject(path: "/repo/project-a", displayName: "a", createdAt: .distantPast, lastOpenedAt: .distantPast)
        let projectB = RecentProject(path: "/repo/project-b", displayName: "b", createdAt: .distantPast, lastOpenedAt: .distantPast)

        model.selectProject(projectA)
        try await waitUntil { clientA.newSessionCwds == ["/repo/project-a"] }
        model.draft = "hello a"
        model.sendDraft()
        try await waitUntil { clientA.prompts.count == 1 }

        model.startNewChat()
        model.selectProject(projectB)
        try await waitUntil { clientB.newSessionCwds == ["/repo/project-b"] }
        model.draft = "hello b"
        model.sendDraft()
        try await waitUntil { clientB.prompts.count == 1 }

        // Killing these processes without first telling the backend it's
        // done with "a1"/"b1" would leave both sessions considered "open"
        // by a now-dead process, and a future relaunch's freshly spawned
        // process for either project would be refused when it tries to
        // reconnect ("already open in another process").
        await model.prepareForTermination()

        #expect(clientA.closedSessionIdsSnapshot == ["a1"])
        #expect(clientB.closedSessionIdsSnapshot == ["b1"])
    }

    /// Opt-in only (`LEVEL5_RUN_REAL_DEVIN_INTEGRATION=1`): proves *why*
    /// `prepareForTermination` must actually run before a process dies —
    /// without it (simulating a `pkill`/`SIGKILL`/crash that bypasses
    /// `Level5AppDelegate` entirely, leaving the old `devin acp` process
    /// orphaned but still running), a reconnect from a fresh process is
    /// refused by real Devin's own session-locking, not by anything in this
    /// app's own logic.
    @Test("Skipping session close before a process dies reproduces real Devin's 'already open in another process'")
    func realDevinOrphanedProcessBlocksReconnect() async throws {
        guard ProcessInfo.processInfo.environment["LEVEL5_RUN_REAL_DEVIN_INTEGRATION"] == "1" else {
            print("Skipping real Devin integration: set LEVEL5_RUN_REAL_DEVIN_INTEGRATION=1 and be logged into the devin CLI")
            return
        }
        guard DevinRuntime.resolveExecutableURL() != nil else {
            print("Skipping real Devin integration: no devin executable on PATH")
            return
        }

        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Level5BuildRealDevinTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        let projectPath = projectDirectory.path

        let model1 = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, approvalMode in
                try DevinAgentSessionClient(cwd: cwd, approvalMode: approvalMode)
            }
        )
        let project = RecentProject(path: projectPath, displayName: "real-devin-test", createdAt: .distantPast, lastOpenedAt: .distantPast)
        model1.selectProject(project)
        try await waitUntil("composer primed", timeout: .seconds(60)) {
            !model1.modelOptions.isEmpty
        }
        model1.draft = "Reply with just the word PONG and nothing else."
        model1.sendDraft()
        try await waitUntil("first reply", timeout: .seconds(120)) {
            model1.transcript.contains { $0.messageRole == .agent && $0.messageText?.contains("PONG") == true }
        }
        let sessionId = try #require(model1.activeSessionId)
        // Deliberately *not* calling `model1.prepareForTermination()` here:
        // this leaves its `devin acp` process running, orphaned, exactly as
        // a `pkill`/`SIGKILL`/crash that bypasses `Level5AppDelegate` would.

        let model2 = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, approvalMode in
                try DevinAgentSessionClient(cwd: cwd, approvalMode: approvalMode)
            }
        )
        model2.selectProject(project)
        try await waitUntil("second client's composer primed", timeout: .seconds(60)) {
            !model2.modelOptions.isEmpty
        }
        model2.selectSession(sessionId)
        model2.draft = "Reply with just the word PONG2 and nothing else."
        model2.sendDraft()

        try await waitUntil("reconnect refused by the still-live orphan", timeout: .seconds(30)) {
            model2.transcript.contains { $0.errorText?.contains("already open in another process") == true }
        }

        await model1.prepareForTermination()
        await model2.prepareForTermination()
    }

    /// Opt-in only (`LEVEL5_RUN_REAL_DEVIN_INTEGRATION=1`): spawns the real
    /// `devin acp` CLI twice against the same project directory, mirroring
    /// exactly what a relaunch does — first send creates the session, then
    /// a second `AgentSessionModel`/`DevinAgentSessionClient` pair (a fresh
    /// process, no in-memory context) reconnects to it and sends again.
    /// Unlike `relaunchReconnectPrimingIncludesCwd` (which only proves the
    /// prompt was *sent*), this asserts the agent's actual reply text makes
    /// it back into the transcript, against the real backend rather than
    /// `FakeAgentSessionClient`.
    @Test("A relaunch's real Devin reconnect still gets a real reply, not just an accepted prompt")
    func realDevinRelaunchReconnectGetsReply() async throws {
        guard ProcessInfo.processInfo.environment["LEVEL5_RUN_REAL_DEVIN_INTEGRATION"] == "1" else {
            print("Skipping real Devin integration: set LEVEL5_RUN_REAL_DEVIN_INTEGRATION=1 and be logged into the devin CLI")
            return
        }
        guard DevinRuntime.resolveExecutableURL() != nil else {
            print("Skipping real Devin integration: no devin executable on PATH")
            return
        }

        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Level5BuildRealDevinTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        let projectPath = projectDirectory.path

        let model1 = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, approvalMode in
                try DevinAgentSessionClient(cwd: cwd, approvalMode: approvalMode)
            }
        )
        let project = RecentProject(path: projectPath, displayName: "real-devin-test", createdAt: .distantPast, lastOpenedAt: .distantPast)
        model1.selectProject(project)
        // `selectProject` eagerly kicks off its own composer-priming
        // `session/new` in the background (see
        // `connectAndPrimeComposerSessionForSelectedProjectIfNeeded`);
        // sending immediately races it into a second, concurrent
        // `session/new` against the same freshly spawned process. Wait for
        // that priming to land (surfaced via its `configOptions`) first,
        // matching how `multiProjectClientsSpawnPerProject` avoids the same
        // race against `FakeAgentSessionClient`.
        try await waitUntil("composer primed", timeout: .seconds(60)) {
            !model1.modelOptions.isEmpty
        }
        model1.draft = "Reply with just the word PONG and nothing else."
        model1.sendDraft()
        try await waitUntil("first reply", timeout: .seconds(120)) {
            // Role-gated: the optimistic user echo of this very prompt also
            // contains "PONG" as a substring, so an unscoped search would
            // pass immediately without actually waiting for the agent.
            model1.transcript.contains { $0.messageRole == .agent && $0.messageText?.contains("PONG") == true }
        }
        let sessionId = try #require(model1.activeSessionId)
        await model1.prepareForTermination()

        let model2 = AgentSessionModel(
            backendKind: .devin,
            makeClient: { throw AgentBackendError.missingDevinExecutable },
            makeProjectClient: { cwd, approvalMode in
                try DevinAgentSessionClient(cwd: cwd, approvalMode: approvalMode)
            }
        )
        model2.selectProject(project)
        // Same race as model1's composer-priming `session/new`, but now
        // against `selectSession` + `sendDraft`'s `session/load` +
        // `session/prompt` for the *existing* session instead of a second
        // `session/new` — wait for it to land first.
        try await waitUntil("second client's composer primed", timeout: .seconds(60)) {
            !model2.modelOptions.isEmpty
        }
        model2.selectSession(sessionId)
        model2.draft = "Reply with just the word PONG2 and nothing else."
        model2.sendDraft()

        try await waitUntil("reconnect reply", timeout: .seconds(120)) {
            model2.transcript.contains { $0.messageRole == .agent && $0.messageText?.contains("PONG2") == true }
        }
        try await waitUntil("turn completes cleanly") { model2.isActiveSessionRunning == false }
        await model2.prepareForTermination()
    }
}

private final class FakeAgentSessionClient: AgentSessionClient, @unchecked Sendable {
    struct Prompt: Equatable {
        var sessionId: String
        var text: String
        var blocks: [JSONValue]
    }

    struct ModelRequest: Equatable {
        var sessionId: String
        var modelId: String
    }

    private let lock = NSLock()
    private let continuation: AsyncStream<AcpEvent>.Continuation
    let events: AsyncStream<AcpEvent>
    var initializeCount = 0
    var newSessionCwds: [String] = []
    var newSessionResult = AcpSessionResult(sessionId: "s1")
    var loadedSessionIds: [String] = []
    var loadSessionCwds: [String?] = []
    var loadReplay: [String: [AgentTranscriptEvent]] = [:]
    var loadSessionFailures: Set<String> = []
    var closedSessionIds: [String] = []
    var deletedSessionIds: [String] = []
    var deleteSessionFailures: Set<String> = []
    var modelOptionSessionIds: [String?] = []
    var modelOptionsResult: (options: [ComposerModelOption], currentModelId: String?) = (
        [
            .init(id: "mock-fast", label: "Mock Fast"),
            .init(id: "mock-pro", label: "Mock Pro")
        ],
        "mock-pro"
    )
    var slashCommandsResult: [ComposerCommand] = [
        .init(name: "plan", commandDescription: "Create a plan"),
        .init(name: "review", commandDescription: "Review code")
    ]
    /// Mirrors real Devin's lack of a request/response discovery API: when
    /// set, `listModelOptions`/`listSlashCommands` throw instead of
    /// returning an empty success.
    var throwsOnDiscovery = false
    /// When set, `newSession` emits `available_commands_update` for these
    /// names before returning its result, mirroring real Devin's wire order.
    var availableCommandNamesOnNewSession: [String]?
    var setModelRequests: [ModelRequest] = []
    var setModelFailures: Set<String> = []
    var cancelledSessionIds: [String] = []
    var cancelFailures: Set<String> = []
    var cancelledPermissionRequestIds: [AcpRpcID] = []
    var permissionResponses: [PermissionResponse] = []
    var permissionResponseFailures: Set<AcpRpcID> = []
    var prompts: [Prompt] = []
    var promptFailures: Set<String> = []
    var failBeforeUserEchoPrompts: Set<String> = []
    var exitOnPrompts: Set<String> = []
    var userEchoChunksByPrompt: [String: [String]] = [:]
    var blockBeforeUserEchoPrompts: Set<String> = []
    var blocksSetModel = false
    var blocksPrompts = false
    var blocksNewSession = false
    private var setModelContinuation: CheckedContinuation<Void, Never>?
    private var setModelReleasePermits = 0
    private var newSessionContinuation: CheckedContinuation<Void, Never>?
    private var newSessionReleasePermits = 0
    private var userEchoContinuations: [CheckedContinuation<Void, Never>] = []
    private var userEchoReleasePermits = 0
    private var promptContinuations: [CheckedContinuation<Void, Never>] = []
    private var promptReleasePermits = 0

    var promptSessionIds: [String] {
        lock.withLock { prompts.map(\.sessionId) }
    }

    var loadSessionCwdsSnapshot: [String?] {
        lock.withLock { loadSessionCwds }
    }

    var closedSessionIdsSnapshot: [String] {
        lock.withLock { closedSessionIds }
    }

    var setModelRequestsSnapshot: [ModelRequest] {
        lock.withLock { setModelRequests }
    }

    var modelOptionSessionIdsSnapshot: [String?] {
        lock.withLock { modelOptionSessionIds }
    }

    var permissionResponsesSnapshot: [PermissionResponse] {
        lock.withLock { permissionResponses }
    }

    var cancelledSessionIdsSnapshot: [String] {
        lock.withLock { cancelledSessionIds }
    }

    var cancelledPermissionRequestIdsSnapshot: [AcpRpcID] {
        lock.withLock { cancelledPermissionRequestIds }
    }

    init() {
        var captured: AsyncStream<AcpEvent>.Continuation!
        events = AsyncStream { continuation in
            captured = continuation
        }
        continuation = captured
    }

    func initialize() async throws {
        lock.withLock { initializeCount += 1 }
    }

    func newSession(cwd: String) async throws -> AcpSessionResult {
        lock.withLock { newSessionCwds.append(cwd) }
        // Real Devin streams `session/update` notifications (including
        // `available_commands_update`) on the wire *before* the session/new
        // RPC response arrives. Mirror that ordering here so tests can
        // exercise the same race a real backend produces.
        if let names = lock.withLock({ availableCommandNamesOnNewSession }) {
            emitAvailableCommands(newSessionResult.sessionId ?? "", names: names)
        }
        if lock.withLock({ blocksNewSession }) {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if newSessionReleasePermits > 0 {
                        newSessionReleasePermits -= 1
                        return true
                    }
                    newSessionContinuation = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }
        return newSessionResult
    }

    func loadSession(sessionId: String, cwd: String?) async throws -> AcpSessionResult {
        lock.withLock {
            loadedSessionIds.append(sessionId)
            loadSessionCwds.append(cwd)
        }
        if lock.withLock({ loadSessionFailures.contains(sessionId) }) {
            throw FakeClientError.promptFailed
        }
        for event in lock.withLock({ loadReplay[sessionId] ?? [] }) {
            emitTranscriptEvent(event, sessionId: sessionId)
        }
        return .init(sessionId: sessionId)
    }

    func closeSession(sessionId: String) async throws {
        lock.withLock { closedSessionIds.append(sessionId) }
    }

    func deleteSession(sessionId: String) async throws {
        lock.withLock { deletedSessionIds.append(sessionId) }
        if lock.withLock({ deleteSessionFailures.contains(sessionId) }) {
            // Mirrors real Devin, which doesn't implement `session/delete`
            // at all ("Method not found").
            throw FakeClientError.promptFailed
        }
    }

    func listModelOptions(sessionId: String?) async throws -> (options: [ComposerModelOption], currentModelId: String?) {
        if lock.withLock({ throwsOnDiscovery }) {
            throw AgentBackendError.discoveryUnsupported
        }
        return lock.withLock {
            modelOptionSessionIds.append(sessionId)
            return modelOptionsResult
        }
    }

    func listSlashCommands(sessionId: String?) async throws -> [ComposerCommand] {
        if lock.withLock({ throwsOnDiscovery }) {
            throw AgentBackendError.discoveryUnsupported
        }
        return lock.withLock { slashCommandsResult }
    }

    func setModel(sessionId: String, modelId: String) async throws -> AcpSessionResult {
        lock.withLock { setModelRequests.append(.init(sessionId: sessionId, modelId: modelId)) }
        if lock.withLock({ blocksSetModel }) {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if setModelReleasePermits > 0 {
                        setModelReleasePermits -= 1
                        return true
                    }
                    setModelContinuation = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }
        if lock.withLock({ setModelFailures.contains(modelId) }) {
            throw FakeClientError.promptFailed
        }
        return .init(sessionId: sessionId, configOptions: [[
            "id": "model",
            "currentValue": .string(modelId),
            "options": .array(modelOptionsResult.options.map { option in
                [
                    "value": .string(option.id),
                    "name": .string(option.label)
                ]
            })
        ]])
    }

    func prompt(sessionId: String, blocks: [JSONValue]) async throws -> AcpPromptResult {
        let text = blocks.textBlockText
        lock.withLock { prompts.append(.init(sessionId: sessionId, text: text, blocks: blocks)) }
        if lock.withLock({ failBeforeUserEchoPrompts.contains(text) }) {
            throw FakeClientError.promptFailed
        }
        if lock.withLock({ blockBeforeUserEchoPrompts.contains(text) }) {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if userEchoReleasePermits > 0 {
                        userEchoReleasePermits -= 1
                        return true
                    }
                    userEchoContinuations.append(continuation)
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }
        let userChunks = lock.withLock { userEchoChunksByPrompt[text] ?? [text] }
        for chunk in userChunks {
            emitUserText(sessionId, chunk)
        }
        if lock.withLock({ exitOnPrompts.contains(text) }) {
            emitProcessExit()
            throw AcpTransportError.processExited(7)
        }
        if lock.withLock({ blocksPrompts }) {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if promptReleasePermits > 0 {
                        promptReleasePermits -= 1
                        return true
                    }
                    promptContinuations.append(continuation)
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }
        if lock.withLock({ promptFailures.contains(text) }) {
            throw FakeClientError.promptFailed
        }
        emitAgentText(sessionId, "response \(text)")
        lock.withLock {
            loadReplay[sessionId, default: []].append(.messageChunk(role: .user, messageId: UUID().uuidString, text: text))
            loadReplay[sessionId, default: []].append(.messageChunk(role: .agent, messageId: UUID().uuidString, text: "response \(text)"))
        }
        return .init(stopReason: "end_turn")
    }

    func cancel(sessionId: String) async throws {
        lock.withLock { cancelledSessionIds.append(sessionId) }
        if lock.withLock({ cancelFailures.contains(sessionId) }) {
            throw FakeClientError.promptFailed
        }
    }

    func respondToPermissionRequest(_ response: PermissionResponse) async throws {
        lock.withLock { permissionResponses.append(response) }
        if lock.withLock({ permissionResponseFailures.contains(response.requestId) }) {
            throw FakeClientError.promptFailed
        }
    }

    func cancelPermissionRequest(_ requestId: AcpRpcID) async throws {
        lock.withLock { cancelledPermissionRequestIds.append(requestId) }
    }

    func terminate() {}

    func releaseNextPrompt() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            if promptContinuations.isEmpty {
                promptReleasePermits += 1
                return nil
            }
            return promptContinuations.removeFirst()
        }
        continuation?.resume()
    }

    func releaseNextUserEcho() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            if userEchoContinuations.isEmpty {
                userEchoReleasePermits += 1
                return nil
            }
            return userEchoContinuations.removeFirst()
        }
        continuation?.resume()
    }

    func releaseSetModel() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard let continuation = setModelContinuation else {
                setModelReleasePermits += 1
                return nil
            }
            setModelContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func releaseNewSession() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard let continuation = newSessionContinuation else {
                newSessionReleasePermits += 1
                return nil
            }
            newSessionContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func emitUserText(_ sessionId: String, _ text: String) {
        emitText(sessionId, role: "user_message_chunk", text: text)
    }

    func emitAgentText(_ sessionId: String, _ text: String) {
        emitText(sessionId, role: "agent_message_chunk", text: text)
    }

    func emitProcessExit() {
        continuation.yield(.processExit(.init(status: 7, reason: "test")))
    }

    func emitUsage(_ sessionId: String, used: Int, size: Int) {
        continuation.yield(.notification(method: AcpMethod.sessionUpdate, params: [
            "sessionId": .string(sessionId),
            "update": [
                "sessionUpdate": "usage_update",
                "used": .number(Double(used)),
                "size": .number(Double(size))
            ]
        ]))
    }

    /// Mirrors real Devin's `available_commands_update` `session/update`
    /// notification, which is how slash commands (including skills) arrive
    /// for a backend with no discovery request/response API.
    func emitAvailableCommands(_ sessionId: String, names: [String]) {
        continuation.yield(.notification(method: AcpMethod.sessionUpdate, params: [
            "sessionId": .string(sessionId),
            "update": [
                "sessionUpdate": "available_commands_update",
                "availableCommands": .array(names.map { name in
                    ["name": .string(name), "description": .string("\(name) description")]
                })
            ]
        ]))
    }

    func emitPermissionRequest(
        id: AcpRpcID,
        sessionId: String,
        options: [JSONValue] = [
            ["optionId": "allow-once", "name": "Allow once", "kind": "allow_once"],
            ["optionId": "allow-always", "name": "Always allow mock edits", "kind": "allow_always"],
            ["optionId": "reject-once", "name": "Reject", "kind": "reject_once"]
        ]
    ) {
        continuation.yield(.serverRequest(id: id, method: AcpMethod.sessionRequestPermission, params: [
            "sessionId": .string(sessionId),
            "toolCall": [
                "toolCallId": "tool-1",
                "title": "Applying protected mock edit",
                "kind": "edit",
                "status": "pending",
                "content": [[
                    "type": "content",
                    "content": [
                        "type": "text",
                        "text": "This is a simulated protected action."
                    ]
                ]],
                "rawInput": [
                    "reason": "exercise permission UI"
                ]
            ],
            "options": .array(options)
        ]))
    }

    /// Mirrors a real backend's `session_info_update` `session/update`
    /// notification (e.g. a title change) so tests can exercise the
    /// hidden-session guard without going through a removed `session/list`.
    func emitSessionInfoUpdate(_ sessionId: String, title: String) {
        continuation.yield(.notification(method: AcpMethod.sessionUpdate, params: [
            "sessionId": .string(sessionId),
            "update": [
                "sessionUpdate": "session_info_update",
                "title": .string(title)
            ]
        ]))
    }

    func emitTranscriptEvent(_ transcriptEvent: AgentTranscriptEvent, sessionId: String) {
        switch transcriptEvent {
        case let .messageChunk(role, messageId, text, _):
            emitText(
                sessionId,
                role: role == .user ? "user_message_chunk" : "agent_message_chunk",
                messageId: messageId,
                text: text
            )
        case let .plan(_, entries):
            continuation.yield(.notification(method: AcpMethod.sessionUpdate, params: [
                "sessionId": .string(sessionId),
                "update": [
                    "sessionUpdate": "plan",
                    "entries": .array(entries.map { entry in
                        [
                            "content": .string(entry.content),
                            "status": .string(entry.status),
                            "priority": .string(entry.priority ?? "medium")
                        ]
                    })
                ]
            ]))
        case let .tool(toolCallId, title, kind, status, text):
            var update: [String: JSONValue] = [
                "sessionUpdate": "tool_call",
                "toolCallId": .string(toolCallId)
            ]
            if let title { update["title"] = .string(title) }
            if let kind { update["kind"] = .string(kind) }
            if let status { update["status"] = .string(status) }
            if let text {
                update["content"] = [[
                    "type": "content",
                    "content": [
                        "type": "text",
                        "text": .string(text)
                    ]
                ]]
            }
            continuation.yield(.notification(method: AcpMethod.sessionUpdate, params: [
                "sessionId": .string(sessionId),
                "update": .object(update)
            ]))
        case let .usage(usage):
            emitUsage(sessionId, used: usage.used ?? 0, size: usage.size ?? 0)
        case let .references(references):
            continuation.yield(.notification(method: AcpMethod.sessionUpdate, params: [
                "sessionId": .string(sessionId),
                "update": [
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("tool-\(UUID().uuidString)"),
                    "title": .string("References"),
                    "kind": .string("fetch"),
                    "status": .string("completed"),
                    "_meta": [
                        "references": .array(references.map { reference in
                            [
                                "title": .string(reference.title),
                                "uri": .string(reference.uri)
                            ]
                        })
                    ]
                ]
            ]))
        case .toolExpansion, .status, .error, .stopReason:
            break
        }
    }

    private func emitText(_ sessionId: String, role: String, messageId: String? = nil, text: String) {
        var update: [String: JSONValue] = [
            "sessionUpdate": .string(role),
            "content": [
                "type": "text",
                "text": .string(text)
            ]
        ]
        if let messageId {
            update["messageId"] = .string(messageId)
        }
        let continuation = continuation
        let event = AcpEvent.notification(method: AcpMethod.sessionUpdate, params: [
            "sessionId": .string(sessionId),
            "update": .object(update)
        ])
        continuation.yield(event)
    }
}

private enum FakeClientError: Error {
    case promptFailed
}

private final class FakeClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [FakeAgentSessionClient]

    init(_ clients: [FakeAgentSessionClient]) {
        self.clients = clients
    }

    func next() -> FakeAgentSessionClient {
        lock.withLock { clients.removeFirst() }
    }
}

private final class FailingAfterFirstClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let client: FakeAgentSessionClient
    private var callCount = 0

    init(_ client: FakeAgentSessionClient) {
        self.client = client
    }

    func next() throws -> FakeAgentSessionClient {
        try lock.withLock {
            callCount += 1
            if callCount == 1 {
                return client
            }
            throw FakeClientError.promptFailed
        }
    }
}

private func waitUntil(
    _ label: String = "condition",
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let start = ContinuousClock.now
    while await !condition() {
        if start.duration(to: .now) > timeout {
            throw WaitError.timedOut(label)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum WaitError: Error {
    case timedOut(String)
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private extension RecentProject {
    static func fixture(path: String) -> RecentProject {
        RecentProject(
            path: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private extension AgentTranscriptItem {
    var messageRole: AgentTranscriptRole? {
        guard case let .message(message) = kind else { return nil }
        return message.role
    }

    var messageText: String? {
        guard case let .message(message) = kind else { return nil }
        return message.text
    }

    var errorText: String? {
        guard case let .error(error) = kind else { return nil }
        return error.text
    }

    var statusText: String? {
        guard case let .status(status) = kind else { return nil }
        return status.text
    }
}

private extension [AgentTranscriptItem] {
    var userMessageTexts: [String] {
        compactMap { item in
            guard case let .message(message) = item.kind, message.role == .user else { return nil }
            return message.text
        }
    }
}

private extension [JSONValue] {
    var textBlockText: String {
        compactMap { value -> String? in
            guard let object = value.objectValue else { return nil }
            guard object["type"]?.stringValue == "text" else { return nil }
            return object["text"]?.stringValue
        }
        .joined()
    }
}

/// An isolated on-disk `SessionPersistenceStore`, matching the temp-database
/// conventions of `RecentProjectStoreTests`/`SessionPersistenceStoreTests`.
private struct PersistenceFixture {
    /// Mirrors `AgentSessionModel.sharedClientKey`: the mock backend always
    /// routes every project through one shared client/project key.
    static let sharedProjectKey = "shared"

    let store: SessionPersistenceStore

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Level5BuildTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try Level5Database(
            databaseURL: root.appendingPathComponent("level5.sqlite"),
            migrations: SessionPersistenceStore.migrations
        )
        store = SessionPersistenceStore(database: database)
    }
}
