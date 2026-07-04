import Foundation
import Level5Core
import Testing
@testable import Level5BuildApp

@Suite("Agent session model", .serialized)
@MainActor
struct AgentSessionModelTests {
    @Test("Backend selector honors mock only when mock backends are allowed")
    func backendSelectorHonorsDebugGate() {
        let environment = ["LEVEL5_USE_ACP_MOCK": "1"]

        #expect(AgentBackendSelector(environment: environment, allowsMockBackend: true).selectedBackend == .acpMock)
        #expect(AgentBackendSelector(environment: environment, allowsMockBackend: false).selectedBackend == .unavailable)
    }

    @Test("Default backend selector allows mock in debug builds")
    func defaultBackendSelectorAllowsMockInDebugBuilds() {
        #if DEBUG
        #expect(AgentBackendSelector(environment: ["LEVEL5_USE_ACP_MOCK": "1"]).selectedBackend == .acpMock)
        #else
        #expect(AgentBackendSelector(environment: ["LEVEL5_USE_ACP_MOCK": "1"]).selectedBackend == .unavailable)
        #endif
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

    @Test("Startup initializes and loads paginated session summaries")
    func startupLoadsSessionSummaries() async throws {
        let client = FakeAgentSessionClient()
        client.listResults = [
            .init(sessions: [
                .init(sessionId: "older", cwd: "/tmp/older", title: "Older", updatedAt: "2024-01-01T00:00:00.000Z"),
                .init(sessionId: "newer", cwd: "/tmp/newer", title: "Newer", updatedAt: "2024-01-02T00:00:00.000Z")
            ], nextCursor: "2")
        ]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil { model.sessions.count == 2 }

        #expect(client.initializeCount == 1)
        #expect(client.listCursors == [nil])
        #expect(model.sessions.map(\.sessionId) == ["newer", "older"])
        #expect(model.nextCursor == "2")
    }

    @Test("Startup discovery populates new chat model and slash commands")
    func startupDiscoveryPopulatesComposerState() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil { model.modelOptions.count == 2 && model.slashCommands.count == 2 }

        #expect(model.draft.selectedModelId == "mock-pro")
        #expect(model.slashCommands.map(\.name) == ["plan", "review"])
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

        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
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
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
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

        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
        model.draft.appendText("s1 draft")
        model.selectModel("mock-fast")
        try await waitUntil { client.setModelRequestsSnapshot == [.init(sessionId: "s1", modelId: "mock-fast")] }

        model.selectSession("s2")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1", "s2"] }
        try await waitUntil { client.modelOptionSessionIdsSnapshot == [nil, "s1", "s2"] }
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

    @Test("Selecting a session loads replay and future sends use that session")
    func selectingSessionLoadsReplayAndSendsToSameSession() async throws {
        let client = FakeAgentSessionClient()
        client.loadReplay["s1"] = [
            .messageChunk(role: .user, messageId: "u1", text: "Previous prompt"),
            .messageChunk(role: .agent, messageId: "a1", text: "Previous answer")
        ]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        try await waitUntil { model.transcript.count == 2 }
        model.draft = "Next prompt"
        model.sendDraft()
        try await waitUntil { client.prompts.contains { $0.text == "Next prompt" } }

        #expect(client.loadedSessionIds == ["s1"])
        #expect(client.prompts.last?.sessionId == "s1")
    }

    @Test("Composer drafts are scoped per selected session")
    func composerDraftsAreScopedPerSession() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
        model.draft.appendText("draft one")

        model.selectSession("s2")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1", "s2"] }
        #expect(model.draft.serializedText.isEmpty)
        model.draft.appendText("draft two")

        model.selectSession("s1")
        #expect(model.draft.serializedText == "draft one")

        model.selectSession("s2")
        #expect(model.draft.serializedText == "draft two")
    }

    @Test("Selecting a session does not change sidebar recency order")
    func selectingSessionDoesNotChangeSidebarOrder() async throws {
        let client = FakeAgentSessionClient()
        client.listResults = [
            .init(sessions: [
                .init(sessionId: "older", cwd: "/tmp/older", title: "Older", updatedAt: "2024-01-01T00:00:00.000Z"),
                .init(sessionId: "newer", cwd: "/tmp/newer", title: "Newer", updatedAt: "2024-01-02T00:00:00.000Z")
            ])
        ]
        client.loadReplay["older"] = [
            .messageChunk(role: .user, messageId: "u-old", text: "old prompt"),
            .messageChunk(role: .agent, messageId: "a-old", text: "old response")
        ]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil("loaded sessions") { model.sessions.count == 2 }
        #expect(model.sessions.map(\.sessionId) == ["newer", "older"])

        model.selectSession("older")
        try await waitUntil("loaded older transcript") { model.transcript.count == 2 }
        #expect(model.sessions.map(\.sessionId) == ["newer", "older"])

        model.draft = "new work"
        model.sendDraft()
        try await waitUntil("older prompted") { client.promptSessionIds == ["older"] }
        try await waitUntil("older moved first") { model.sessions.map(\.sessionId) == ["older", "newer"] }
    }

    @Test("Live message after selecting a session updates sidebar recency")
    func liveMessageAfterSelectingSessionUpdatesSidebarOrder() async throws {
        let client = FakeAgentSessionClient()
        client.listResults = [
            .init(sessions: [
                .init(sessionId: "older", cwd: "/tmp/older", title: "Older", updatedAt: "2024-01-01T00:00:00.000Z"),
                .init(sessionId: "newer", cwd: "/tmp/newer", title: "Newer", updatedAt: "2024-01-02T00:00:00.000Z")
            ])
        ]
        client.loadReplay["older"] = [
            .messageChunk(role: .user, messageId: "u-old", text: "old prompt"),
            .messageChunk(role: .agent, messageId: "a-old", text: "old response")
        ]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil("loaded sessions") { model.sessions.count == 2 }
        model.selectSession("older")
        try await waitUntil("loaded older transcript") { model.transcript.count == 2 }
        #expect(model.sessions.map(\.sessionId) == ["newer", "older"])

        try await Task.sleep(for: .milliseconds(30))
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
        try await waitUntil("loaded s1") { client.loadedSessionIdsSnapshot == ["s1"] }
        #expect(model.activeTranscriptFollowsTail)
        model.setActiveTranscriptFollowsTail(false)
        #expect(model.activeTranscriptFollowsTail == false)

        model.selectSession("s2")
        try await waitUntil("loaded s2") { client.loadedSessionIdsSnapshot == ["s1", "s2"] }
        #expect(model.activeTranscriptFollowsTail)

        model.selectSession("s1")
        #expect(model.activeTranscriptFollowsTail == false)
    }

    @Test("Session replay keeps follow-tail enabled while loading")
    func sessionReplayKeepsFollowTailEnabledWhileLoading() async throws {
        let client = FakeAgentSessionClient()
        client.blocksLoad = true
        client.loadReplay["s1"] = [
            .messageChunk(role: .user, messageId: "u1", text: "old prompt"),
            .messageChunk(role: .agent, messageId: "a1", text: "old response")
        ]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        try await waitUntil("load started") { client.loadedSessionIdsSnapshot == ["s1"] }
        model.setActiveTranscriptFollowsTail(false)

        #expect(model.activeTranscriptFollowsTail)

        client.releaseLoad()
        try await waitUntil("load finished") { model.transcript.count == 2 }
        model.setActiveTranscriptFollowsTail(false)

        #expect(model.activeTranscriptFollowsTail == false)
    }

    @Test("Sending respects manual scroll-away follow-tail state")
    func sendingRespectsManualScrollAwayFollowTailState() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.selectSession("s1")
        try await waitUntil("loaded s1") { client.loadedSessionIdsSnapshot == ["s1"] }
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
        try await waitUntil("loaded s1") { client.loadedSessionIdsSnapshot == ["s1"] }

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
        try await waitUntil("loaded s1") { client.loadedSessionIdsSnapshot == ["s1"] }
        model.draft = "one"
        model.sendDraft()
        try await waitUntil("prompted s1") { client.promptSessionIds == ["s1"] }

        model.selectSession("s2")
        try await waitUntil("loaded s2") { client.loadedSessionIdsSnapshot == ["s1", "s2"] }
        model.draft = "two"
        model.sendDraft()
        try await waitUntil("prompted s2") { client.promptSessionIds == ["s1", "s2"] }

        try await waitUntil("active s2 transcript") { model.transcript.first?.messageText == "two" }

        model.selectSession("s1")
        try await waitUntil("active s1 transcript") { model.transcript.first?.messageText == "one" }
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

    @Test("Ask approval stores active pending request and blocks composer")
    func askApprovalStoresActivePendingRequestAndBlocksComposer() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
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

        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
        client.emitPermissionRequest(id: .int(12), sessionId: "s1")
        try await waitUntil { model.activePermissionRequest != nil }

        model.respondToPermission(optionId: "allow-always")
        try await waitUntil { client.permissionResponsesSnapshot.count == 1 }

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

        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
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
        client.listResults = [
            .init(sessions: [
                .init(sessionId: "s1", title: "One"),
                .init(sessionId: "s2", title: "Two")
            ])
        ]
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.start()
        try await waitUntil { model.sessions.count == 2 }
        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
        client.emitPermissionRequest(id: .int(22), sessionId: "s2")
        try await waitUntil {
            model.sessions.first(where: { $0.sessionId == "s2" })?.isAwaitingPermission == true
        }

        #expect(model.activeSessionId == "s1")
        #expect(model.activePermissionRequest == nil)
        #expect(model.canEditComposer)
    }

    @Test("Approve for me auto-approves mock permission with status note")
    func approveForMeAutoApprovesMockPermissionWithStatusNote() async throws {
        let client = FakeAgentSessionClient()
        let model = AgentSessionModel(
            backendKind: .acpMock,
            makeClient: { client },
            approvalModePreferenceStore: .ephemeral
        )

        model.selectApprovalMode(.approveForMe)
        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
        client.emitPermissionRequest(id: .int(12), sessionId: "s1")
        try await waitUntil { client.permissionResponsesSnapshot.count == 1 }

        #expect(client.permissionResponsesSnapshot.first?.optionId == "allow-once")
        #expect(model.activePermissionRequest == nil)
        #expect(model.transcript.contains { $0.statusText?.contains("Approve for me") == true })
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
        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
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
        model.selectSession("s1")
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
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
        try await waitUntil { client.loadedSessionIdsSnapshot == ["s1"] }
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

    @Test("Delete refreshes list and clears active deleted session")
    func deleteRefreshesAndClearsActiveSession() async throws {
        let client = FakeAgentSessionClient()
        client.listResults = [
            .init(sessions: [.init(sessionId: "s1", title: "One")]),
            .init(sessions: [])
        ]
        let model = AgentSessionModel(backendKind: .acpMock, makeClient: { client })

        model.start()
        try await waitUntil { model.sessions.count == 1 }
        model.selectSession("s1")
        model.deleteSession("s1")
        try await waitUntil { client.deletedSessionIds == ["s1"] && model.sessions.isEmpty }

        #expect(model.activeSessionId == nil)
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
    var listCursors: [String?] = []
    var listResults: [AcpSessionListResult] = [.init()]
    var newSessionCwds: [String] = []
    var newSessionResult = AcpSessionResult(sessionId: "s1")
    var loadedSessionIds: [String] = []
    var loadReplay: [String: [AgentTranscriptEvent]] = [:]
    var deletedSessionIds: [String] = []
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
    var setModelRequests: [ModelRequest] = []
    var setModelFailures: Set<String> = []
    var permissionResponses: [PermissionResponse] = []
    var permissionResponseFailures: Set<AcpRpcID> = []
    var prompts: [Prompt] = []
    var promptFailures: Set<String> = []
    var failBeforeUserEchoPrompts: Set<String> = []
    var exitOnPrompts: Set<String> = []
    var userEchoChunksByPrompt: [String: [String]] = [:]
    var blocksSetModel = false
    var blocksLoad = false
    var blocksPrompts = false
    private var setModelContinuation: CheckedContinuation<Void, Never>?
    private var setModelReleasePermits = 0
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var promptContinuations: [CheckedContinuation<Void, Never>] = []
    private var promptReleasePermits = 0

    var loadedSessionIdsSnapshot: [String] {
        lock.withLock { loadedSessionIds }
    }

    var promptSessionIds: [String] {
        lock.withLock { prompts.map(\.sessionId) }
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

    func listSessions(cursor: String?) async throws -> AcpSessionListResult {
        lock.withLock {
            listCursors.append(cursor)
            return listResults.isEmpty ? .init() : listResults.removeFirst()
        }
    }

    func newSession(cwd: String) async throws -> AcpSessionResult {
        lock.withLock { newSessionCwds.append(cwd) }
        return newSessionResult
    }

    func loadSession(sessionId: String, cwd: String?) async throws -> AcpSessionResult {
        lock.withLock { loadedSessionIds.append(sessionId) }
        if lock.withLock({ blocksLoad }) {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    loadContinuation = continuation
                }
            }
        }
        for event in lock.withLock({ loadReplay[sessionId] ?? [] }) {
            emitTranscriptEvent(event, sessionId: sessionId)
        }
        return .init(sessionId: sessionId)
    }

    func deleteSession(sessionId: String) async throws {
        lock.withLock { deletedSessionIds.append(sessionId) }
    }

    func listModelOptions(sessionId: String?) async throws -> (options: [ComposerModelOption], currentModelId: String?) {
        lock.withLock {
            modelOptionSessionIds.append(sessionId)
            return modelOptionsResult
        }
    }

    func listSlashCommands(sessionId: String?) async throws -> [ComposerCommand] {
        lock.withLock { slashCommandsResult }
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

    func respondToPermissionRequest(_ response: PermissionResponse) async throws {
        lock.withLock { permissionResponses.append(response) }
        if lock.withLock({ permissionResponseFailures.contains(response.requestId) }) {
            throw FakeClientError.promptFailed
        }
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

    func releaseLoad() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            let continuation = loadContinuation
            loadContinuation = nil
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

    private func emitTranscriptEvent(_ transcriptEvent: AgentTranscriptEvent, sessionId: String) {
        switch transcriptEvent {
        case let .messageChunk(role, messageId, text, _):
            emitText(
                sessionId,
                role: role == .user ? "user_message_chunk" : "agent_message_chunk",
                messageId: messageId,
                text: text
            )
        case let .plan(_, status, text):
            continuation.yield(.notification(method: AcpMethod.sessionUpdate, params: [
                "sessionId": .string(sessionId),
                "update": [
                    "sessionUpdate": "plan",
                    "entries": [[
                        "content": .string(text),
                        "status": .string(status ?? "in_progress")
                    ]]
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
        case .status, .error, .stopReason:
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
