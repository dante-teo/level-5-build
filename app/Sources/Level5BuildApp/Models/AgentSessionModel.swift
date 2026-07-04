import Foundation
import Level5Core

public struct AgentSessionRow: Identifiable, Equatable, Sendable {
    public var id: String { sessionId }
    public var sessionId: String
    public var title: String
    public var detail: String
    public var updatedAt: Date?
    public var observedAt: Date?
    public var isRunning: Bool

    public init(
        sessionId: String,
        title: String,
        detail: String,
        updatedAt: Date? = nil,
        observedAt: Date? = nil,
        isRunning: Bool = false
    ) {
        self.sessionId = sessionId
        self.title = title
        self.detail = detail
        self.updatedAt = updatedAt
        self.observedAt = observedAt
        self.isRunning = isRunning
    }
}

public struct QueuedPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

public enum AgentAvailability: Equatable, Sendable {
    case connecting
    case available
    case unavailable(String)
    case disconnected(String)

    public var disablesAgentActions: Bool {
        switch self {
        case .available, .connecting, .disconnected:
            false
        case .unavailable:
            true
        }
    }
}

@MainActor
@Observable
final class AgentSessionModel {
    var draft = ""
    private(set) var availability: AgentAvailability
    private(set) var sessions: [AgentSessionRow] = []
    private(set) var activeSessionId: String?
    private(set) var selectedProject: RecentProject?
    private(set) var nextCursor: String?
    private(set) var runtimeMessage: String?

    private var transcriptStates: [String: AgentTranscriptState] = [:]
    private var queues: [String: [QueuedPrompt]] = [:]
    private var followTailBySessionId: [String: Bool] = [:]
    private var runningSessionIds: Set<String> = []
    private var loadingSessionIds: Set<String> = []
    private var pendingUserEchoes: [String: [String]] = [:]
    private var client: AgentSessionClient?
    private var connectionTask: Task<Bool, Never>?
    private var eventTask: Task<Void, Never>?
    private let backendKind: AgentBackendKind
    private let makeClient: @Sendable () throws -> AgentSessionClient
    private let now: @Sendable () -> Date
    private let homeDirectoryPath: String
    private let isoFormatter = ISO8601DateFormatter()
    private let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        backendKind: AgentBackendKind,
        makeClient: @escaping @Sendable () throws -> AgentSessionClient,
        now: @escaping @Sendable () -> Date = Date.init,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.backendKind = backendKind
        self.makeClient = makeClient
        self.now = now
        self.homeDirectoryPath = homeDirectoryPath
        switch backendKind {
        case .acpMock:
            availability = .connecting
        case .unavailable:
            availability = .unavailable("Agent runtime unavailable")
        }
    }

    convenience init(
        selector: AgentBackendSelector = AgentBackendSelector()
    ) {
        let kind = selector.selectedBackend
        self.init(
            backendKind: kind,
            makeClient: {
                switch kind {
                case .acpMock:
                    return AcpTcpAgentSessionClient(environment: selector.environment)
                case .unavailable:
                    throw AgentBackendError.missingMockStartScript
                }
            }
        )
    }

    var transcript: [AgentTranscriptItem] {
        guard let activeSessionId else { return [] }
        return transcriptStates[activeSessionId]?.renderableItems ?? []
    }

    var activeQueue: [QueuedPrompt] {
        guard let activeSessionId else { return [] }
        return queues[activeSessionId] ?? []
    }

    var activeTranscriptFollowsTail: Bool {
        guard let activeSessionId else { return true }
        return followTailBySessionId[activeSessionId, default: true]
    }

    var isActiveSessionRunning: Bool {
        activeSessionId.map { runningSessionIds.contains($0) } ?? false
    }

    var isNewSession: Bool {
        activeSessionId == nil
    }

    var isProjectSelectionAvailable: Bool {
        isNewSession
    }

    var selectedProjectPath: String? {
        selectedProject?.path
    }

    var canSendWithButton: Bool {
        canEditComposer
            && !isActiveSessionRunning
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canEditComposer: Bool {
        switch backendKind {
        case .acpMock:
            true
        case .unavailable:
            false
        }
    }

    func start() {
        guard case .acpMock = backendKind else { return }
        Task {
            await ensureConnected()
            await refreshSessions(reset: true)
        }
    }

    func startNewChat() {
        activeSessionId = nil
        draft = ""
    }

    func selectProject(_ project: RecentProject) {
        guard isProjectSelectionAvailable else { return }
        selectedProject = project
    }

    func clearSelectedProject() {
        guard isProjectSelectionAvailable else { return }
        selectedProject = nil
    }

    func sendDraft() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            draft = ""
            return
        }
        guard case .acpMock = backendKind else {
            runtimeMessage = "Agent runtime unavailable"
            return
        }
        runtimeMessage = activeSessionId == nil ? "Starting agent runtime..." : "Sending..."

        Task {
            if let activeSessionId {
                if runningSessionIds.contains(activeSessionId) {
                    draft = ""
                    enqueue(message, for: activeSessionId)
                } else {
                    runningSessionIds.insert(activeSessionId)
                    updateRunningFlags()
                    await send(message, to: activeSessionId, isAlreadyMarkedRunning: true)
                }
            } else {
                await createSessionAndSend(message)
            }
        }
    }

    func removeQueuedPrompt(_ prompt: QueuedPrompt) {
        guard let activeSessionId else { return }
        queues[activeSessionId]?.removeAll { $0.id == prompt.id }
    }

    func setActiveTranscriptFollowsTail(_ followsTail: Bool) {
        guard let activeSessionId else { return }
        if followsTail == false, loadingSessionIds.contains(activeSessionId) {
            return
        }
        followTailBySessionId[activeSessionId] = followsTail
    }

    func selectSession(_ sessionId: String) {
        activeSessionId = sessionId
        if followTailBySessionId[sessionId] == nil {
            followTailBySessionId[sessionId] = true
        }
        Task {
            guard await ensureConnected() else { return }
            guard let client else { return }
            transcriptStates[sessionId] = AgentTranscriptState()
            loadingSessionIds.insert(sessionId)
            do {
                _ = try await client.loadSession(sessionId: sessionId, cwd: nil)
                await clearLoadingAfterReplayDrain(sessionId)
            } catch {
                loadingSessionIds.remove(sessionId)
                appendError(title: "Load failed", text: "Failed to load session: \(error)", key: "load-failed", to: sessionId)
            }
        }
    }

    func loadMoreSessions() {
        Task {
            await refreshSessions(reset: false)
        }
    }

    func deleteSession(_ sessionId: String) {
        Task {
            guard await ensureConnected() else { return }
            guard let client else { return }
            do {
                try await client.deleteSession(sessionId: sessionId)
                transcriptStates[sessionId] = nil
                queues[sessionId] = nil
                followTailBySessionId[sessionId] = nil
                runningSessionIds.remove(sessionId)
                if activeSessionId == sessionId {
                    activeSessionId = nil
                    draft = ""
                }
                await refreshSessions(reset: true)
            } catch {
                appendError(title: "Delete failed", text: "Failed to delete session: \(error)", key: "delete-failed", to: sessionId)
            }
        }
    }

    func clearTranscript() {
        guard let activeSessionId else { return }
        transcriptStates[activeSessionId] = AgentTranscriptState()
    }

    @discardableResult
    private func ensureConnected() async -> Bool {
        if client != nil { return true }
        if let connectionTask {
            return await connectionTask.value
        }
        guard case .acpMock = backendKind else {
            availability = .unavailable("Agent runtime unavailable")
            return false
        }

        availability = .connecting
        runtimeMessage = "Starting agent runtime..."
        let task = Task { @MainActor in
            defer { connectionTask = nil }
            do {
                let client = try makeClient()
                self.client = client
                startEventTask(client.events)
                try await client.initialize()
                availability = .available
                runtimeMessage = nil
                return true
            } catch {
                let message = "Agent runtime unavailable: \(userFacingError(error))"
                availability = .unavailable(message)
                runtimeMessage = message
                self.client = nil
                return false
            }
        }
        connectionTask = task
        return await task.value
    }

    private func refreshSessions(reset: Bool) async {
        guard await ensureConnected() else { return }
        guard let client else { return }
        do {
            let result = try await client.listSessions(cursor: reset ? nil : nextCursor)
            runtimeMessage = nil
            let incoming = result.sessions.map(row)
            if reset {
                sessions = incoming
            } else {
                let existing = Set(sessions.map(\.sessionId))
                sessions.append(contentsOf: incoming.filter { !existing.contains($0.sessionId) })
            }
            nextCursor = result.nextCursor
            sortSessions()
        } catch {
            let message = "Agent runtime disconnected: \(userFacingError(error))"
            availability = .disconnected(message)
            runtimeMessage = message
        }
    }

    private func createSessionAndSend(_ message: String) async {
        guard await ensureConnected() else { return }
        guard let client else { return }
        do {
            let result = try await client.newSession(cwd: selectedProjectPath ?? homeDirectoryPath)
            guard let sessionId = result.sessionId else {
                activeSessionId = nil
                return
            }
            let row = AgentSessionRow(
                sessionId: sessionId,
                title: "New mock agent session",
                detail: folderDetail(selectedProjectPath ?? homeDirectoryPath),
                observedAt: now()
            )
            upsert(row)
            activeSessionId = sessionId
            followTailBySessionId[sessionId] = true
            draft = ""
            await send(message, to: sessionId)
        } catch {
            activeSessionId = nil
            let message = "Agent runtime disconnected: \(userFacingError(error))"
            availability = .disconnected(message)
            runtimeMessage = message
        }
    }

    private func send(_ message: String, to sessionId: String, isAlreadyMarkedRunning: Bool = false) async {
        guard await ensureConnected() else {
            if isAlreadyMarkedRunning {
                runningSessionIds.remove(sessionId)
                updateRunningFlags()
            }
            return
        }
        guard let client else { return }
        loadingSessionIds.remove(sessionId)
        draft = ""
        if !isAlreadyMarkedRunning {
            runningSessionIds.insert(sessionId)
            updateRunningFlags()
        }
        pendingUserEchoes[sessionId, default: []].append(message)
        appendUser(message, to: sessionId)
        markObservedActivity(for: sessionId)
        do {
            let result = try await client.prompt(sessionId: sessionId, text: message)
            runtimeMessage = nil
            apply(.stopReason(result.stopReason), to: sessionId)
        } catch {
            if case .processExited = error as? AcpTransportError {
                let message = "Agent runtime disconnected: \(userFacingError(error))"
                availability = .disconnected(message)
                runtimeMessage = message
                self.client = nil
            }
            appendError(title: "Prompt failed", text: "Prompt failed: \(error)", key: "prompt-failed-\(message)", to: sessionId)
            removePendingUserEcho(message, for: sessionId)
        }
        runningSessionIds.remove(sessionId)
        updateRunningFlags()
        await startNextQueuedPromptIfNeeded(for: sessionId)
    }

    private func enqueue(_ message: String, for sessionId: String) {
        queues[sessionId, default: []].append(QueuedPrompt(text: message))
        markObservedActivity(for: sessionId)
    }

    private func startNextQueuedPromptIfNeeded(for sessionId: String) async {
        guard runningSessionIds.contains(sessionId) == false else { return }
        guard var queue = queues[sessionId], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        queues[sessionId] = queue
        await send(next.text, to: sessionId)
    }

    private func startEventTask(_ events: AsyncStream<AcpEvent>) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: AcpEvent) async {
        switch event {
        case let .notification(method, params):
            guard method == AcpMethod.sessionUpdate, let params else { return }
            handleSessionUpdate(params)
        case let .serverRequest(id, method, _):
            if method == AcpMethod.sessionRequestPermission {
                try? await client?.respondToPermissionRequest(id: id, allow: true)
            }
        case let .diagnostic(diagnostic):
            appendStatus(title: "Diagnostic", text: diagnostic.message, to: activeSessionId)
        case let .stderr(line):
            appendStatus(title: "Runtime stderr", text: line, to: activeSessionId)
        case let .processExit(exit):
            let message = "Agent runtime disconnected: status \(exit.status)"
            availability = .disconnected(message)
            runtimeMessage = message
            client = nil
            appendError(title: "Runtime exited", text: "Agent runtime exited with status \(exit.status).", key: "process-exit-\(exit.status)", to: activeSessionId)
        case .activity:
            break
        }
    }

    private func handleSessionUpdate(_ params: JSONValue) {
        guard let update = try? AcpProtocolCoding.decode(AcpSessionUpdate.self, from: params) else { return }
        let sessionId = update.sessionId
        guard let object = update.update.objectValue else { return }
        let kind = object["sessionUpdate"]?.stringValue

        switch kind {
        case "user_message_chunk":
            guard let event = AgentTranscriptNormalizer.events(from: update).first else { return }
            markLiveMessageActivity(for: sessionId)
            if case let .messageChunk(_, _, text, _) = event, suppressPendingUserEchoChunk(text, for: sessionId) {
                return
            } else {
                apply(event, to: sessionId)
            }
        case "agent_message_chunk":
            markLiveMessageActivity(for: sessionId)
            apply(AgentTranscriptNormalizer.events(from: update), to: sessionId)
        case "session_info_update":
            updateSessionInfo(sessionId: sessionId, object: object)
        case "plan", "tool_call", "tool_call_update", "usage_update":
            apply(AgentTranscriptNormalizer.events(from: update), to: sessionId)
        default:
            break
        }
    }

    private func updateSessionInfo(sessionId: String, object: [String: JSONValue]) {
        let title = object["title"]?.stringValue
        let updatedAtString = object["updatedAt"]?.stringValue
        let updatedAt = updatedAtString.flatMap(parseDate)
        if let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
            if let title, !title.isEmpty {
                sessions[index].title = title
            }
            if let updatedAt {
                sessions[index].updatedAt = updatedAt
            }
        } else {
            upsert(.init(
                sessionId: sessionId,
                title: title?.nonEmpty ?? sessionId,
                detail: "Session",
                updatedAt: updatedAt,
                observedAt: nil,
                isRunning: runningSessionIds.contains(sessionId)
            ))
        }
        sortSessions()
    }

    private func row(from summary: AcpSessionSummary) -> AgentSessionRow {
        AgentSessionRow(
            sessionId: summary.sessionId,
            title: summary.title?.nonEmpty ?? summary.sessionId,
            detail: folderDetail(summary.cwd),
            updatedAt: summary.updatedAt.flatMap(parseDate),
            observedAt: nil,
            isRunning: runningSessionIds.contains(summary.sessionId)
        )
    }

    private func upsert(_ row: AgentSessionRow) {
        if let index = sessions.firstIndex(where: { $0.sessionId == row.sessionId }) {
            sessions[index] = row
        } else {
            sessions.insert(row, at: 0)
        }
        sortSessions()
    }

    private func sortSessions() {
        sessions.sort { left, right in
            (left.observedAt ?? left.updatedAt ?? .distantPast) > (right.observedAt ?? right.updatedAt ?? .distantPast)
        }
    }

    private func markObservedActivity(for sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        sessions[index].observedAt = now()
        sortSessions()
    }

    private func markLiveMessageActivity(for sessionId: String) {
        guard !loadingSessionIds.contains(sessionId) else { return }
        markObservedActivity(for: sessionId)
    }

    private func clearLoadingAfterReplayDrain(_ sessionId: String) async {
        for _ in 0..<3 {
            await Task.yield()
        }
        loadingSessionIds.remove(sessionId)
    }

    private func updateRunningFlags() {
        for index in sessions.indices {
            sessions[index].isRunning = runningSessionIds.contains(sessions[index].sessionId)
        }
    }

    private func appendUser(_ text: String, to sessionId: String) {
        apply(.messageChunk(role: .user, messageId: "local-user-\(UUID().uuidString)", text: text), to: sessionId)
    }

    private func suppressPendingUserEchoChunk(_ text: String, for sessionId: String) -> Bool {
        guard var echoes = pendingUserEchoes[sessionId], let first = echoes.first else { return false }
        guard first.hasPrefix(text) else { return false }
        let remainder = String(first.dropFirst(text.count))
        if remainder.isEmpty {
            echoes.removeFirst()
        } else {
            echoes[0] = remainder
        }
        pendingUserEchoes[sessionId] = echoes.isEmpty ? nil : echoes
        return true
    }

    private func removePendingUserEcho(_ text: String, for sessionId: String) {
        guard var echoes = pendingUserEchoes[sessionId] else { return }
        if let index = echoes.firstIndex(of: text) {
            echoes.remove(at: index)
        }
        pendingUserEchoes[sessionId] = echoes.isEmpty ? nil : echoes
    }

    private func appendStatus(title: String, text: String, to sessionId: String?) {
        guard let sessionId else { return }
        apply(.status(title: title, text: text), to: sessionId)
    }

    private func appendError(title: String, text: String, key: String? = nil, to sessionId: String?) {
        guard let sessionId else { return }
        apply(.error(title: title, text: text, replacementKey: key), to: sessionId)
    }

    private func apply(_ events: [AgentTranscriptEvent], to sessionId: String) {
        for event in events {
            apply(event, to: sessionId)
        }
    }

    private func apply(_ event: AgentTranscriptEvent, to sessionId: String) {
        var state = transcriptStates[sessionId] ?? AgentTranscriptState()
        state.apply(event)
        transcriptStates[sessionId] = state
    }

    private func folderDetail(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "No folder" }
        let url = URL(fileURLWithPath: path)
        let folder = url.lastPathComponent.nonEmpty ?? path
        return "\(folder) - \(path)"
    }

    private func parseDate(_ value: String) -> Date? {
        isoFormatter.date(from: value) ?? fractionalISOFormatter.date(from: value)
    }

    private func userFacingError(_ error: Error) -> String {
        String(describing: error)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
