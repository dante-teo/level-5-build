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
        try await waitUntil { model.transcript.contains { $0.role == .agent } }

        #expect(client.newSessionCwds == ["/Users/tester"])
        #expect(client.prompts.map(\.sessionId) == ["s1"])
        #expect(client.prompts.map(\.text) == ["Build it"])
        #expect(model.activeSessionId == "s1")
        #expect(model.sessions.map(\.sessionId) == ["s1"])
        #expect(model.transcript.first?.role == .user)
        #expect(model.transcript.contains { $0.role == .agent })
    }

    @Test("Selecting a session loads replay and future sends use that session")
    func selectingSessionLoadsReplayAndSendsToSameSession() async throws {
        let client = FakeAgentSessionClient()
        client.loadReplay["s1"] = [
            .init(role: .user, text: "Previous prompt"),
            .init(role: .agent, text: "Previous answer")
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
            .init(role: .user, text: "old prompt"),
            .init(role: .agent, text: "old response")
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
            .init(role: .user, text: "old prompt"),
            .init(role: .agent, text: "old response")
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

        try await waitUntil("active s2 transcript") { model.transcript.first?.text == "two" }

        model.selectSession("s1")
        try await waitUntil("active s1 transcript") { model.transcript.first?.text == "one" }
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

        model.removeQueuedPrompt(model.activeQueue[1])
        #expect(model.activeQueue.map(\.text) == ["second"])

        client.releaseNextPrompt()
        try await waitUntil { client.prompts.count == 2 }
        #expect(client.prompts.map(\.text) == ["first", "second"])
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

        #expect(model.transcript.contains { $0.role == .status && $0.text.contains("Prompt failed") })
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
    var loadReplay: [String: [LocalTranscriptItem]] = [:]
    var deletedSessionIds: [String] = []
    var prompts: [Prompt] = []
    var promptFailures: Set<String> = []
    var exitOnPrompts: Set<String> = []
    var blocksPrompts = false
    private var promptContinuations: [CheckedContinuation<Void, Never>] = []
    private var promptReleasePermits = 0

    var loadedSessionIdsSnapshot: [String] {
        lock.withLock { loadedSessionIds }
    }

    var promptSessionIds: [String] {
        lock.withLock { prompts.map(\.sessionId) }
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
        for item in lock.withLock({ loadReplay[sessionId] ?? [] }) {
            switch item.role {
            case .user:
                emitUserText(sessionId, item.text)
            case .agent:
                emitAgentText(sessionId, item.text)
            case .status:
                break
            }
        }
        return .init(sessionId: sessionId)
    }

    func deleteSession(sessionId: String) async throws {
        lock.withLock { deletedSessionIds.append(sessionId) }
    }

    func prompt(sessionId: String, text: String) async throws -> AcpPromptResult {
        lock.withLock { prompts.append(.init(sessionId: sessionId, text: text)) }
        emitUserText(sessionId, text)
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
            loadReplay[sessionId, default: []].append(.init(role: .user, text: text))
            loadReplay[sessionId, default: []].append(.init(role: .agent, text: "response \(text)"))
        }
        return .init(stopReason: "end_turn")
    }

    func respondToPermissionRequest(id: AcpRpcID, allow: Bool) async throws {}

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

    func emitUserText(_ sessionId: String, _ text: String) {
        emitText(sessionId, role: "user_message_chunk", text: text)
    }

    func emitAgentText(_ sessionId: String, _ text: String) {
        emitText(sessionId, role: "agent_message_chunk", text: text)
    }

    func emitProcessExit() {
        continuation.yield(.processExit(.init(status: 7, reason: "test")))
    }

    private func emitText(_ sessionId: String, role: String, text: String) {
        let continuation = continuation
        let event = AcpEvent.notification(method: AcpMethod.sessionUpdate, params: [
            "sessionId": .string(sessionId),
            "update": [
                "sessionUpdate": .string(role),
                "content": [
                    "type": "text",
                    "text": .string(text)
                ]
            ]
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
