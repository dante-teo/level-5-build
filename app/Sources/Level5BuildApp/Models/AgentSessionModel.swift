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
    public var isAwaitingPermission: Bool
    public var hasCompletedTurn: Bool

    public init(
        sessionId: String,
        title: String,
        detail: String,
        updatedAt: Date? = nil,
        observedAt: Date? = nil,
        isRunning: Bool = false,
        isAwaitingPermission: Bool = false,
        hasCompletedTurn: Bool = false
    ) {
        self.sessionId = sessionId
        self.title = title
        self.detail = detail
        self.updatedAt = updatedAt
        self.observedAt = observedAt
        self.isRunning = isRunning
        self.isAwaitingPermission = isAwaitingPermission
        self.hasCompletedTurn = hasCompletedTurn
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

private struct ActiveTurn {
    let id: UUID
    let generation: Int
    var lastInboundActivity: Date
    var watchdogTask: Task<Void, Never>?
}

private enum TurnCancelReason {
    case manual
    case idleTimeout
}

@MainActor
@Observable
final class AgentSessionModel {
    var draft = ComposerDraft()
    private(set) var availability: AgentAvailability
    private(set) var sessions: [AgentSessionRow] = []
    private(set) var activeSessionId: String?
    private(set) var selectedProject: RecentProject?
    private(set) var activeSessionProjectPath: String?
    private(set) var dashboardState: ProjectDashboardState?
    private(set) var nextCursor: String?
    private(set) var runtimeMessage: String?
    private(set) var modelOptions: [ComposerModelOption] = []
    private(set) var slashCommands: [ComposerCommand] = []
    private(set) var sessionModelSaveInFlight = false
    private(set) var approvalMode: ApprovalMode
    private(set) var pendingPermissionRequests: [String: PermissionRequest] = [:]

    private var transcriptStates: [String: AgentTranscriptState] = [:]
    private var sessionCwdBySessionId: [String: String] = [:]
    private var sessionProjectPathBySessionId: [String: String] = [:]
    private var sessionProjectKeyBySessionId: [String: String] = [:]
    private var recentProjectPaths: Set<String> = []
    private var completedTurnSessionIds: Set<String> = []
    private var queues: [String: [QueuedPrompt]] = [:]
    private var draftsBySessionId: [String: ComposerDraft] = [:]
    private var followTailBySessionId: [String: Bool] = [:]
    private var activeTurns: [String: ActiveTurn] = [:]
    private var staleTurnGenerationBySessionId: [String: Int] = [:]
    private var loadingSessionIds: Set<String> = []
    private var pendingUserEchoes: [String: [String]] = [:]
    private var currentModelBySessionId: [String: String] = [:]
    private var pendingModelBySessionId: [String: String] = [:]
    private var persistedNewChatModelByBackend: [AgentBackendKind: String] = [:]
    private var defaultModelId: String?
    private var dashboardRefreshGeneration = 0
    /// One ACP client per project. Keyed by `Self.sharedClientKey` for the
    /// mock backend (a single shared server handles every project), or by
    /// the normalized project path for Devin (one spawned `devin acp`
    /// process per project directory, enabling true concurrent sessions).
    private var clients: [String: AgentSessionClient] = [:]
    private var clientGenerationByProjectKey: [String: Int] = [:]
    private var connectionTasksByProjectKey: [String: Task<Bool, Never>] = [:]
    private var eventTasksByProjectKey: [String: Task<Void, Never>] = [:]
    private var pendingApprovalModeRestartProjectKeys: Set<String> = []
    /// A session created eagerly (before the user sent anything) purely to
    /// discover models/slash-commands for a "new chat" composer targeting
    /// that project. Reused as the real session on first send. Empty string
    /// means "creation in flight" (reservation to avoid duplicate creates).
    private var primingSessionIdByProjectKey: [String: String] = [:]
    private let backendKind: AgentBackendKind
    private let makeClient: @Sendable () throws -> AgentSessionClient
    private let makeProjectClient: (@Sendable (String, ApprovalMode) throws -> AgentSessionClient)?
    private let approvalModePreferenceStore: ApprovalModePreferenceStore
    private let gitStatusProvider: @Sendable (String) async -> ProjectGitStatus
    private let now: @Sendable () -> Date
    private let turnIdleTimeoutMilliseconds: Int
    private let homeDirectoryPath: String
    private let isoFormatter = ISO8601DateFormatter()
    private let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let sharedClientKey = "shared"

    init(
        backendKind: AgentBackendKind,
        makeClient: @escaping @Sendable () throws -> AgentSessionClient,
        makeProjectClient: (@Sendable (String, ApprovalMode) throws -> AgentSessionClient)? = nil,
        approvalModePreferenceStore: ApprovalModePreferenceStore = .userDefaults,
        gitStatusProvider: @escaping @Sendable (String) async -> ProjectGitStatus = { cwd in
            await ProjectGitStatusService().status(cwd: cwd)
        },
        now: @escaping @Sendable () -> Date = Date.init,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        turnIdleTimeoutMilliseconds: Int? = nil,
        unavailableReason: String? = nil
    ) {
        self.backendKind = backendKind
        self.makeClient = makeClient
        self.makeProjectClient = makeProjectClient
        self.approvalModePreferenceStore = approvalModePreferenceStore
        self.gitStatusProvider = gitStatusProvider
        approvalMode = approvalModePreferenceStore.load(backendKind)
        self.now = now
        self.homeDirectoryPath = homeDirectoryPath
        self.turnIdleTimeoutMilliseconds = turnIdleTimeoutMilliseconds
            ?? ProcessInfo.processInfo.environment["LEVEL5_ACP_TURN_IDLE_TIMEOUT_MS"].flatMap(Int.init)
            ?? 120_000
        switch backendKind {
        case .acpMock, .devin:
            availability = .connecting
        case .unavailable:
            availability = .unavailable(unavailableReason ?? "Agent runtime unavailable")
        }
    }

    convenience init(
        selector: AgentBackendSelector = AgentBackendSelector()
    ) {
        let kind = selector.selectedBackend
        let makeClient: @Sendable () throws -> AgentSessionClient = {
            switch kind {
            case .acpMock:
                return AcpTcpAgentSessionClient(environment: selector.environment)
            case .devin, .unavailable:
                throw AgentBackendError.missingMockStartScript
            }
        }
        let devinProjectClient: @Sendable (String, ApprovalMode) throws -> AgentSessionClient = { cwd, approvalMode in
            try DevinAgentSessionClient(cwd: cwd, approvalMode: approvalMode, environment: selector.environment)
        }
        let makeProjectClient: (@Sendable (String, ApprovalMode) throws -> AgentSessionClient)?
        if kind == .devin {
            makeProjectClient = devinProjectClient
        } else {
            makeProjectClient = nil
        }
        self.init(
            backendKind: kind,
            makeClient: makeClient,
            makeProjectClient: makeProjectClient,
            unavailableReason: selector.unavailableReason
        )
    }

    /// Routing key for the client that owns `projectPath` (or the home
    /// directory, when no project is selected). Mock always resolves to the
    /// single shared client; Devin resolves to that project's own process.
    private func projectKey(for projectPath: String?) -> String {
        guard backendKind == .devin else { return Self.sharedClientKey }
        return RecentProjectStore.normalizedPath(projectPath ?? homeDirectoryPath)
    }

    private func projectKey(forSessionId sessionId: String) -> String {
        sessionProjectKeyBySessionId[sessionId] ?? projectKey(for: selectedProjectPath)
    }

    /// The project whose sessions the sidebar currently represents: the
    /// active session's project when one is open, otherwise the project
    /// picked for the next new chat (or home).
    private var currentSidebarProjectKey: String {
        if let activeSessionId, let key = sessionProjectKeyBySessionId[activeSessionId] {
            return key
        }
        return projectKey(for: selectedProjectPath)
    }

    /// Whether `key` is the project the user is currently looking at, i.e.
    /// whether global `availability`/`runtimeMessage` should reflect that
    /// project's client state. Mock only ever has one project in play.
    private func isActiveProjectKey(_ key: String) -> Bool {
        guard backendKind == .devin else { return true }
        return key == currentSidebarProjectKey
    }

    var transcript: [AgentTranscriptItem] {
        guard let activeSessionId else { return [] }
        return transcriptStates[activeSessionId]?.renderableItems ?? []
    }

    var activePlan: AgentPlanState? {
        guard let activeSessionId else { return nil }
        return transcriptStates[activeSessionId]?.plan
    }

    var activeUsage: AgentTranscriptUsage? {
        guard let activeSessionId else { return nil }
        return transcriptStates[activeSessionId]?.latestUsage
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
        activeSessionId.map { activeTurns[$0] != nil } ?? false
    }

    var activePermissionRequest: PermissionRequest? {
        activeSessionId.flatMap { pendingPermissionRequests[$0] }
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

    var activeReferences: [AgentReference] {
        guard let activeSessionId else { return [] }
        let references = transcriptStates[activeSessionId]?.references ?? []
        guard let projectPath = activeSessionProjectPath else {
            return references.filter { $0.kind == .web }
        }
        return references.filter { reference in
            switch reference.kind {
            case .web:
                return true
            case .file:
                return !Self.fileReference(reference, isInside: projectPath)
            }
        }
    }

    var canSendWithButton: Bool {
        canEditComposer
            && !isActiveSessionRunning
            && !draft.isEmpty
    }

    var canEditComposer: Bool {
        guard activePermissionRequest == nil else { return false }
        return switch backendKind {
        case .acpMock, .devin:
            true
        case .unavailable:
            false
        }
    }

    func start() {
        guard backendKind == .acpMock || backendKind == .devin else { return }
        let key = currentSidebarProjectKey
        Task {
            await ensureConnected(projectKey: key)
            await refreshSessions(reset: true, projectKey: key)
            if isNewSession {
                await primeComposerSession(forProjectKey: key)
            }
        }
    }

    func startNewChat() {
        saveActiveDraft()
        activeSessionId = nil
        activeSessionProjectPath = nil
        dashboardState = nil
        dashboardRefreshGeneration += 1
        draft.clearAfterSend()
        applyNewChatPersistedModel()
    }

    func setRecentProjects(_ projects: [RecentProject]) {
        recentProjectPaths = Set(projects.map { RecentProjectStore.normalizedPath($0.path) })
        reconcileSessionProjectPaths()
        updateActiveProjectPathFromSession()
    }

    func selectProject(_ project: RecentProject) {
        guard isProjectSelectionAvailable else { return }
        selectedProject = project
        refreshSessionsForSelectedProjectIfNeeded()
    }

    func clearSelectedProject() {
        guard isProjectSelectionAvailable else { return }
        selectedProject = nil
        refreshSessionsForSelectedProjectIfNeeded()
    }

    /// Devin spawns one process per project, so switching the "new chat"
    /// project needs to (re)load that project's own session list and get a
    /// live agent connection ready (see `primeComposerSession`). Mock has a
    /// single shared server that already lists and discovers everything, so
    /// this is a no-op there.
    private func refreshSessionsForSelectedProjectIfNeeded() {
        guard backendKind == .devin, isNewSession else { return }
        let key = projectKey(for: selectedProjectPath)
        Task {
            await ensureConnected(projectKey: key)
            await refreshSessions(reset: true, projectKey: key)
            await primeComposerSession(forProjectKey: key)
        }
    }

    /// Real Devin has no way to discover models or slash commands/skills
    /// without an active session (see `DevinAgentSessionClient`), so a "new
    /// chat" composer would otherwise show nothing until the user's first
    /// send. To make the composer feel already-connected — matching what a
    /// user expects when they open a new chat or pick a project — silently
    /// create a session as soon as the project's client connects, and reuse
    /// it as the real session once the user actually sends (see
    /// `createSessionAndSend`). An un-messaged session is never persisted by
    /// Devin's own session store, so an abandoned priming session (e.g. the
    /// user switches projects before sending) costs nothing and never shows
    /// up in `session/list`.
    private func primeComposerSession(forProjectKey key: String) async {
        guard backendKind == .devin else { return }
        guard primingSessionIdByProjectKey[key] == nil else { return }
        guard let client = clients[key] else { return }
        primingSessionIdByProjectKey[key] = ""
        do {
            let result = try await client.newSession(cwd: key)
            guard let sessionId = result.sessionId else {
                primingSessionIdByProjectKey[key] = nil
                return
            }
            guard clients[key] != nil else {
                // The client was torn down (approval-mode restart, crash,
                // project switch) while we awaited; the priming session is
                // moot.
                primingSessionIdByProjectKey[key] = nil
                return
            }
            primingSessionIdByProjectKey[key] = sessionId
            sessionProjectKeyBySessionId[sessionId] = key
            applyModelConfig(result.configOptions, sessionId: sessionId)
            if isNewSession, projectKey(for: selectedProjectPath) == key {
                defaultModelId = currentModelBySessionId[sessionId] ?? defaultModelId
                applyNewChatPersistedModel()
            }
        } catch {
            primingSessionIdByProjectKey[key] = nil
        }
    }

    func refreshProjectDashboard() {
        refreshDashboardStatus()
    }

    func sendDraft() {
        let snapshot = draft
        guard !snapshot.isEmpty else {
            draft.clearAfterSend()
            return
        }
        guard backendKind == .acpMock || backendKind == .devin else {
            runtimeMessage = "Agent runtime unavailable"
            return
        }
        runtimeMessage = activeSessionId == nil ? "Starting agent runtime..." : "Sending..."

        Task {
            if let activeSessionId {
                if activeTurns[activeSessionId] != nil {
                    draft.clearAfterSend()
                    enqueue(snapshot, for: activeSessionId)
                } else {
                    reserveTurn(sessionId: activeSessionId)
                    await send(snapshot, to: activeSessionId, isAlreadyMarkedRunning: true)
                }
            } else {
                await createSessionAndSend(snapshot)
            }
        }
    }

    func cancelActiveTurn() {
        guard let activeSessionId else { return }
        cancelTurn(sessionId: activeSessionId, reason: .manual)
    }

    func addAttachments(urls: [URL], kind: ComposerAttachment.Kind) {
        draft.addAttachments(urls: urls, kind: kind)
    }

    func removeAttachment(_ attachment: ComposerAttachment) {
        draft.removeAttachment(id: attachment.id)
    }

    func acceptSlashCommand(_ command: ComposerCommand) {
        if case let .text(id, text)? = draft.parts.last, let range = text.currentSlashTokenRange {
            let remaining = String(text[..<range.lowerBound])
            if remaining.isEmpty {
                draft.parts.removeLast()
            } else {
                draft.parts[draft.parts.count - 1] = .text(id: id, remaining)
            }
        }
        draft.insertCommand(command)
        draft.appendText(" ")
    }

    func selectModel(_ modelId: String) {
        guard modelOptions.contains(where: { $0.id == modelId }) else { return }
        if isNewSession {
            draft.selectedModelId = modelId
            persistedNewChatModelByBackend[backendKind] = modelId
            return
        }
        guard let activeSessionId else { return }
        let sessionId = activeSessionId
        let key = projectKey(forSessionId: sessionId)
        let previous = currentModelBySessionId[sessionId] ?? defaultModelId
        currentModelBySessionId[sessionId] = modelId
        draft.selectedModelId = modelId
        pendingModelBySessionId[sessionId] = modelId
        sessionModelSaveInFlight = true
        Task {
            guard await ensureConnected(projectKey: key), let client = clients[key] else {
                rollbackModelChange(sessionId: sessionId, previous: previous)
                return
            }
            do {
                let result = try await client.setModel(sessionId: sessionId, modelId: modelId)
                clearPendingModelChange(sessionId: sessionId)
                applyModelConfig(result.configOptions, sessionId: sessionId)
                runtimeMessage = nil
            } catch {
                rollbackModelChange(sessionId: sessionId, previous: previous)
                runtimeMessage = "Model change failed: \(userFacingError(error))"
            }
        }
    }

    func selectApprovalMode(_ mode: ApprovalMode) {
        let previous = approvalMode
        approvalMode = mode
        approvalModePreferenceStore.save(mode, backendKind)
        guard backendKind == .devin, mode != previous else { return }
        restartClientsForApprovalModeChange()
    }

    /// Real Devin's permission mode is fixed at process startup (empirically,
    /// `session/set_mode` only affects the agent's Normal/Plan/Ask mode, not
    /// tool-approval enforcement), so changing approval mode restarts the
    /// affected project's `devin acp` process. Projects with a turn in
    /// flight are restarted once that turn finishes instead of killing it.
    private func restartClientsForApprovalModeChange() {
        for key in clients.keys {
            let hasActiveTurn = activeTurns.keys.contains { sessionProjectKeyBySessionId[$0] == key }
            if hasActiveTurn {
                pendingApprovalModeRestartProjectKeys.insert(key)
            } else {
                terminateClient(forProjectKey: key)
            }
        }
    }

    private func terminateClient(forProjectKey key: String) {
        eventTasksByProjectKey[key]?.cancel()
        eventTasksByProjectKey[key] = nil
        clients[key]?.terminate()
        clients[key] = nil
        clientGenerationByProjectKey[key, default: 0] += 1
        pendingApprovalModeRestartProjectKeys.remove(key)
        primingSessionIdByProjectKey[key] = nil
    }

    private func applyDeferredApprovalModeRestartIfNeeded(projectKey key: String) {
        guard pendingApprovalModeRestartProjectKeys.contains(key) else { return }
        let stillRunning = activeTurns.keys.contains { sessionProjectKeyBySessionId[$0] == key }
        guard !stillRunning else { return }
        terminateClient(forProjectKey: key)
    }

    func respondToPermission(optionId: String) {
        guard let request = activePermissionRequest else { return }
        Task {
            await sendPermissionResponse(
                request: request,
                optionId: optionId,
                localInstructionText: nil,
                followUpInstruction: nil
            )
        }
    }

    func rejectPermissionWithInstructions(_ instructionText: String) {
        guard let request = activePermissionRequest else { return }
        guard let option = request.rejectInstructionOption else { return }
        let trimmed = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await sendPermissionResponse(
                request: request,
                optionId: option.optionId,
                localInstructionText: trimmed.nonEmpty,
                followUpInstruction: trimmed.nonEmpty
            )
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
        saveActiveDraft()
        activeSessionId = sessionId
        updateActiveProjectPathFromSession()
        ensureSessionRowExists(for: sessionId)
        restoreDraft(for: sessionId)
        if followTailBySessionId[sessionId] == nil {
            followTailBySessionId[sessionId] = true
        }
        let key = projectKey(forSessionId: sessionId)
        Task {
            guard await ensureConnected(projectKey: key) else { return }
            guard let client = clients[key] else { return }
                transcriptStates[sessionId] = AgentTranscriptState()
                loadingSessionIds.insert(sessionId)
                do {
                    let result = try await client.loadSession(sessionId: sessionId, cwd: nil)
                sessionProjectKeyBySessionId[sessionId] = key
                applyModelConfig(result.configOptions, sessionId: sessionId)
                await refreshSessionSlashCommands(sessionId, projectKey: key)
                await clearLoadingAfterReplayDrain(sessionId)
            } catch {
                loadingSessionIds.remove(sessionId)
                appendError(title: "Load failed", text: "Failed to load session: \(error)", key: "load-failed", to: sessionId)
            }
        }
    }

    func loadMoreSessions() {
        let key = currentSidebarProjectKey
        Task {
            await refreshSessions(reset: false, projectKey: key)
        }
    }

    func deleteSession(_ sessionId: String) {
        let key = projectKey(forSessionId: sessionId)
        Task {
            guard await ensureConnected(projectKey: key) else { return }
            guard let client = clients[key] else { return }
            do {
                try await client.deleteSession(sessionId: sessionId)
                transcriptStates[sessionId] = nil
                queues[sessionId] = nil
                draftsBySessionId[sessionId] = nil
                followTailBySessionId[sessionId] = nil
                sessionCwdBySessionId[sessionId] = nil
                sessionProjectPathBySessionId[sessionId] = nil
                sessionProjectKeyBySessionId[sessionId] = nil
                pendingPermissionRequests[sessionId] = nil
                completedTurnSessionIds.remove(sessionId)
                activeTurns[sessionId]?.watchdogTask?.cancel()
                activeTurns[sessionId] = nil
                sessions.removeAll { $0.sessionId == sessionId }
                if activeSessionId == sessionId {
                    activeSessionId = nil
                    activeSessionProjectPath = nil
                    dashboardState = nil
                    dashboardRefreshGeneration += 1
                    draft.clearAfterSend()
                    applyNewChatPersistedModel()
                }
                await refreshSessions(reset: true, projectKey: key)
            } catch {
                appendError(title: "Delete failed", text: "Failed to delete session: \(error)", key: "delete-failed", to: sessionId)
            }
        }
    }

    func clearTranscript() {
        guard let activeSessionId else { return }
        transcriptStates[activeSessionId] = AgentTranscriptState()
    }

    private func makeAgentClient(projectKey: String) throws -> AgentSessionClient {
        switch backendKind {
        case .acpMock:
            return try makeClient()
        case .devin:
            guard let makeProjectClient else { throw AgentBackendError.missingDevinExecutable }
            return try makeProjectClient(projectKey, approvalMode)
        case .unavailable:
            throw AgentBackendError.missingMockStartScript
        }
    }

    @discardableResult
    private func ensureConnected(projectKey: String) async -> Bool {
        if clients[projectKey] != nil { return true }
        if let task = connectionTasksByProjectKey[projectKey] {
            return await task.value
        }
        guard backendKind == .acpMock || backendKind == .devin else {
            availability = .unavailable("Agent runtime unavailable")
            return false
        }

        if isActiveProjectKey(projectKey) {
            availability = .connecting
            runtimeMessage = "Starting agent runtime..."
        }
        let task = Task { @MainActor in
            defer { connectionTasksByProjectKey[projectKey] = nil }
            do {
                let client = try makeAgentClient(projectKey: projectKey)
                clients[projectKey] = client
                let generation = (clientGenerationByProjectKey[projectKey] ?? 0) + 1
                clientGenerationByProjectKey[projectKey] = generation
                startEventTask(client.events, generation: generation, projectKey: projectKey)
                try await client.initialize()
                await refreshGlobalComposerDiscovery(projectKey: projectKey)
                if isActiveProjectKey(projectKey) {
                    availability = .available
                    runtimeMessage = nil
                }
                return true
            } catch {
                let message = "Agent runtime unavailable: \(userFacingError(error))"
                if isActiveProjectKey(projectKey) {
                    availability = .unavailable(message)
                    runtimeMessage = message
                }
                clients[projectKey] = nil
                return false
            }
        }
        connectionTasksByProjectKey[projectKey] = task
        return await task.value
    }

    private func refreshSessions(reset: Bool, projectKey: String) async {
        guard await ensureConnected(projectKey: projectKey) else { return }
        guard let client = clients[projectKey] else { return }
        do {
            let result = try await client.listSessions(cursor: reset ? nil : nextCursor)
            if isActiveProjectKey(projectKey) {
                runtimeMessage = nil
            }
            let incoming = result.sessions.map { row(from: $0, projectKey: projectKey) }
            if reset {
                // Only replace this project's own rows: other projects' rows
                // (e.g. one with a Devin turn still running in the
                // background) must survive switching the sidebar's context.
                let incomingIds = Set(incoming.map(\.sessionId))
                sessions.removeAll { sessionProjectKeyBySessionId[$0.sessionId] == projectKey && !incomingIds.contains($0.sessionId) }
                incoming.forEach(upsert)
            } else {
                let existing = Set(sessions.map(\.sessionId))
                sessions.append(contentsOf: incoming.filter { !existing.contains($0.sessionId) })
            }
            nextCursor = result.nextCursor
            sortSessions()
        } catch {
            guard isActiveProjectKey(projectKey) else { return }
            let message = "Agent runtime disconnected: \(userFacingError(error))"
            availability = .disconnected(message)
            runtimeMessage = message
        }
    }

    private func saveActiveDraft() {
        guard let activeSessionId else { return }
        draftsBySessionId[activeSessionId] = draft
    }

    private func restoreDraft(for sessionId: String) {
        if let stored = draftsBySessionId[sessionId] {
            draft = stored
        } else {
            draft = ComposerDraft()
            draft.selectedModelId = currentModelBySessionId[sessionId] ?? defaultModelId ?? modelOptions.first?.id
        }
    }

    private func rollbackModelChange(sessionId: String, previous: String?) {
        currentModelBySessionId[sessionId] = previous
        if activeSessionId == sessionId {
            draft.selectedModelId = previous
        } else if var stored = draftsBySessionId[sessionId] {
            stored.selectedModelId = previous
            draftsBySessionId[sessionId] = stored
        }
        clearPendingModelChange(sessionId: sessionId)
    }

    private func clearPendingModelChange(sessionId: String) {
        pendingModelBySessionId[sessionId] = nil
        sessionModelSaveInFlight = !pendingModelBySessionId.isEmpty
    }

    private func refreshGlobalComposerDiscovery(projectKey: String) async {
        guard let client = clients[projectKey] else { return }
        async let modelsResult = try? client.listModelOptions(sessionId: nil)
        async let commandsResult = try? client.listSlashCommands(sessionId: nil)
        let discoveredModels = await modelsResult
        let discoveredCommands = await commandsResult
        if let discoveredModels {
            modelOptions = discoveredModels.options
            defaultModelId = discoveredModels.currentModelId
            applyNewChatPersistedModel()
        }
        if let discoveredCommands {
            slashCommands = discoveredCommands
        }
    }

    private func refreshSessionSlashCommands(_ sessionId: String, projectKey: String) async {
        guard let client = clients[projectKey] else { return }
        if let commands = try? await client.listSlashCommands(sessionId: sessionId) {
            slashCommands = commands
        }
        if let models = try? await client.listModelOptions(sessionId: sessionId) {
            modelOptions = models.options
            if let current = models.currentModelId {
                currentModelBySessionId[sessionId] = current
                if activeSessionId == sessionId {
                    draft.selectedModelId = current
                }
            }
        }
    }

    private func applyNewChatPersistedModel() {
        let candidate = persistedNewChatModelByBackend[backendKind] ?? defaultModelId ?? modelOptions.first?.id
        if let candidate, modelOptions.contains(where: { $0.id == candidate }) {
            draft.selectedModelId = candidate
        } else {
            draft.selectedModelId = modelOptions.first?.id
        }
    }

    private func applyModelConfig(_ configOptions: [JSONValue], sessionId: String) {
        guard pendingModelBySessionId[sessionId] == nil else { return }
        guard
            let modelConfig = configOptions.compactMap(\.objectValue).first(where: { $0["id"]?.stringValue == "model" })
        else { return }

        let options = modelConfig["options"]?.arrayValue?.compactMap { value -> ComposerModelOption? in
            guard let object = value.objectValue else { return nil }
            guard let id = object["value"]?.stringValue ?? object["id"]?.stringValue else { return nil }
            return ComposerModelOption(
                id: id,
                label: object["name"]?.stringValue,
                modelDescription: object["description"]?.stringValue
            )
        } ?? []
        if !options.isEmpty {
            modelOptions = options
        }
        if let current = modelConfig["currentValue"]?.stringValue {
            currentModelBySessionId[sessionId] = current
            if activeSessionId == sessionId {
                draft.selectedModelId = current
            }
        }
    }

    private func createSessionAndSend(_ snapshot: ComposerDraft) async {
        let key = projectKey(for: selectedProjectPath)
        guard await ensureConnected(projectKey: key) else { return }
        guard let client = clients[key] else { return }
        do {
            let sessionId: String
            let configOptions: [JSONValue]
            if let primedSessionId = primingSessionIdByProjectKey[key], !primedSessionId.isEmpty {
                // Reuse the session `primeComposerSession` already created
                // silently for this project so the composer felt connected
                // before the user sent anything; don't create a second one.
                primingSessionIdByProjectKey[key] = nil
                sessionId = primedSessionId
                configOptions = []
            } else {
                let result = try await client.newSession(cwd: selectedProjectPath ?? homeDirectoryPath)
                guard let newSessionId = result.sessionId else {
                    // Only reset the composer's "new chat" state if the user
                    // is still looking at it: they may have already switched
                    // to a different session/project while this awaited.
                    if isNewSession {
                        activeSessionId = nil
                    }
                    return
                }
                sessionId = newSessionId
                configOptions = result.configOptions
            }
            sessionProjectKeyBySessionId[sessionId] = key
            if let selectedProjectPath {
                let normalized = RecentProjectStore.normalizedPath(selectedProjectPath)
                sessionCwdBySessionId[sessionId] = normalized
                sessionProjectPathBySessionId[sessionId] = normalized
            } else {
                sessionCwdBySessionId[sessionId] = RecentProjectStore.normalizedPath(homeDirectoryPath)
                sessionProjectPathBySessionId[sessionId] = nil
            }
            let row = AgentSessionRow(
                sessionId: sessionId,
                title: backendKind == .devin ? "New Devin session" : "New mock agent session",
                detail: folderDetail(selectedProjectPath ?? homeDirectoryPath),
                observedAt: now()
            )
            upsert(row)
            activeSessionId = sessionId
            updateActiveProjectPathFromSession()
            followTailBySessionId[sessionId] = true
            applyModelConfig(configOptions, sessionId: sessionId)
            await refreshSessionSlashCommands(sessionId, projectKey: key)
            let targetModelId = snapshot.selectedModelId ?? draft.selectedModelId
            if
                let targetModelId,
                targetModelId != currentModelBySessionId[sessionId],
                modelOptions.contains(where: { $0.id == targetModelId })
            {
                do {
                    let configResult = try await client.setModel(sessionId: sessionId, modelId: targetModelId)
                    applyModelConfig(configResult.configOptions, sessionId: sessionId)
                } catch {
                    runtimeMessage = "Model change failed: \(userFacingError(error))"
                }
            }
            draft.clearAfterSend()
            await send(snapshot, to: sessionId)
        } catch {
            // Same rationale as above: don't stomp on state the user has
            // since navigated to while this project's session creation was
            // in flight.
            if isNewSession {
                activeSessionId = nil
            }
            let message = "Agent runtime disconnected: \(userFacingError(error))"
            if isActiveProjectKey(key) {
                availability = .disconnected(message)
                runtimeMessage = message
            }
        }
    }

    private func send(_ snapshot: ComposerDraft, to sessionId: String, isAlreadyMarkedRunning: Bool = false) async {
        let key = projectKey(forSessionId: sessionId)
        guard await ensureConnected(projectKey: key) else {
            if isAlreadyMarkedRunning {
                clearActiveTurn(sessionId)
                updateRunningFlags()
            }
            return
        }
        guard let client = clients[key] else { return }
        let displayMessage = snapshot.previewText
        loadingSessionIds.remove(sessionId)
        draft.clearAfterSend()
        let turnId = beginTurn(sessionId: sessionId)
        pendingUserEchoes[sessionId, default: []].append(displayMessage)
        appendUser(displayMessage, to: sessionId)
        markObservedActivity(for: sessionId)
        do {
            let result = try await client.prompt(sessionId: sessionId, blocks: snapshot.promptBlocks)
            guard isCurrentTurn(sessionId: sessionId, turnId: turnId) else { return }
            if isActiveProjectKey(key) {
                runtimeMessage = nil
            }
            apply(.stopReason(result.stopReason), to: sessionId)
            updateCompletionState(sessionId: sessionId, stopReason: result.stopReason)
            refreshDashboardStatus()
            await drainCurrentTurnEvents(sessionId: sessionId, turnId: turnId)
        } catch {
            guard isCurrentTurn(sessionId: sessionId, turnId: turnId) else { return }
            if case .processExited = error as? AcpTransportError {
                cleanupUnhealthyRuntime(message: "Agent runtime disconnected: \(userFacingError(error))", projectKey: key)
            }
            appendError(title: "Prompt failed", text: "Prompt failed: \(error)", key: "prompt-failed-\(displayMessage)", to: sessionId)
            completedTurnSessionIds.remove(sessionId)
            updateCompletionFlags()
            removePendingUserEcho(displayMessage, for: sessionId)
            refreshDashboardStatus()
            await drainCurrentTurnEvents(sessionId: sessionId, turnId: turnId)
        }
        guard isCurrentTurn(sessionId: sessionId, turnId: turnId) else { return }
        clearActiveTurn(sessionId)
        updateRunningFlags()
        applyDeferredApprovalModeRestartIfNeeded(projectKey: key)
        await startNextQueuedPromptIfNeeded(for: sessionId)
    }

    private func enqueue(_ snapshot: ComposerDraft, for sessionId: String) {
        queues[sessionId, default: []].append(QueuedPrompt(snapshot: snapshot))
        markObservedActivity(for: sessionId)
    }

    private func startNextQueuedPromptIfNeeded(for sessionId: String) async {
        guard activeTurns[sessionId] == nil else { return }
        guard var queue = queues[sessionId], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        queues[sessionId] = queue
        await send(next.snapshot, to: sessionId)
    }

    private func startEventTask(_ events: AsyncStream<AcpEvent>, generation: Int, projectKey: String) {
        eventTasksByProjectKey[projectKey]?.cancel()
        eventTasksByProjectKey[projectKey] = Task { [weak self] in
            for await event in events {
                await self?.handle(event, generation: generation, projectKey: projectKey)
            }
        }
    }

    private func handle(_ event: AcpEvent, generation: Int, projectKey: String) async {
        guard generation == clientGenerationByProjectKey[projectKey] else { return }
        switch event {
        case let .notification(method, params):
            guard method == AcpMethod.sessionUpdate, let params else { return }
            handleSessionUpdate(params, generation: generation, projectKey: projectKey)
        case let .serverRequest(id, method, params):
            if method == AcpMethod.sessionRequestPermission {
                await handlePermissionRequest(id: id, params: params, projectKey: projectKey)
            }
        case let .diagnostic(diagnostic):
            guard isActiveProjectKey(projectKey) else { return }
            appendStatus(title: "Diagnostic", text: diagnostic.message, to: activeSessionId)
        case let .stderr(line):
            guard isActiveProjectKey(projectKey) else { return }
            appendStatus(title: "Runtime stderr", text: line, to: activeSessionId)
        case let .processExit(exit):
            let message = "Agent runtime disconnected: status \(exit.status)"
            let affectedSessionIds = activeTurns.keys.filter { sessionProjectKeyBySessionId[$0] == projectKey }
            cleanupUnhealthyRuntime(message: message, projectKey: projectKey)
            for sessionId in affectedSessionIds {
                appendError(title: "Runtime exited", text: "Agent runtime exited with status \(exit.status).", key: "process-exit-\(exit.status)-\(sessionId)", to: sessionId)
            }
        case .activity:
            break
        }
    }

    private func handlePermissionRequest(id: AcpRpcID, params: JSONValue?, projectKey: String) async {
        guard let request = PermissionRequest.parse(requestId: id, params: params) else {
            if isActiveProjectKey(projectKey) {
                runtimeMessage = "Permission request could not be read."
            }
            return
        }

        switch approvalMode {
        case .ask:
            pendingPermissionRequests[request.sessionId] = request
            refreshWatchdogActivity(for: request.sessionId)
            ensureSessionRowExists(for: request.sessionId)
            updatePermissionFlags()
        case .approveForMe:
            guard let option = request.automaticApprovalOption else {
                if isActiveProjectKey(projectKey) {
                    runtimeMessage = "Permission request had no available options."
                }
                return
            }
            appendStatus(title: "Permission", text: "Approved \"\(request.title)\" (Approve for me).", to: request.sessionId)
            await sendPermissionResponse(
                request: request,
                optionId: option.optionId,
                localInstructionText: nil,
                followUpInstruction: nil
            )
        case .fullAccess:
            guard let option = request.automaticApprovalOption else {
                if isActiveProjectKey(projectKey) {
                    runtimeMessage = "Permission request had no available options."
                }
                return
            }
            await sendPermissionResponse(
                request: request,
                optionId: option.optionId,
                localInstructionText: nil,
                followUpInstruction: nil
            )
        }
    }

    private func sendPermissionResponse(
        request: PermissionRequest,
        optionId: String,
        localInstructionText: String?,
        followUpInstruction: String?
    ) async {
        let key = projectKey(forSessionId: request.sessionId)
        do {
            try await clients[key]?.respondToPermissionRequest(.init(
                requestId: request.requestId,
                optionId: optionId,
                localInstructionText: localInstructionText
            ))
            pendingPermissionRequests[request.sessionId] = nil
            updatePermissionFlags()
            refreshWatchdogActivity(for: request.sessionId)
            if isActiveProjectKey(key) {
                runtimeMessage = nil
            }
            if let followUpInstruction {
                enqueueOrSendInstruction(followUpInstruction, for: request.sessionId)
            }
        } catch {
            pendingPermissionRequests[request.sessionId] = nil
            updatePermissionFlags()
            refreshWatchdogActivity(for: request.sessionId)
            if isActiveProjectKey(key) {
                runtimeMessage = "Permission response failed: \(userFacingError(error))"
            }
        }
    }

    private func enqueueOrSendInstruction(_ text: String, for sessionId: String) {
        var followUp = ComposerDraft()
        followUp.appendText(text)
        if activeTurns[sessionId] != nil {
            enqueue(followUp, for: sessionId)
            return
        }
        Task {
            reserveTurn(sessionId: sessionId)
            await send(followUp, to: sessionId, isAlreadyMarkedRunning: true)
        }
    }

    private func handleSessionUpdate(_ params: JSONValue, generation: Int, projectKey: String) {
        guard let update = try? AcpProtocolCoding.decode(AcpSessionUpdate.self, from: params) else { return }
        let sessionId = update.sessionId
        if sessionProjectKeyBySessionId[sessionId] == nil {
            sessionProjectKeyBySessionId[sessionId] = projectKey
        }
        if let activeTurn = activeTurns[sessionId], activeTurn.generation != generation {
            return
        }
        guard let object = update.update.objectValue else { return }
        let kind = object["sessionUpdate"]?.stringValue

        switch kind {
        case "user_message_chunk":
            guard let event = AgentTranscriptNormalizer.events(from: update).first else { return }
            if isSuppressingStaleTurnOutput(for: sessionId) {
                if case let .messageChunk(_, _, text, _) = event, suppressPendingUserEchoChunk(text, for: sessionId) {
                    clearStaleSuppressionIfPromptEchoCompleted(for: sessionId)
                }
                return
            }
            refreshWatchdogActivity(for: sessionId)
            markLiveMessageActivity(for: sessionId)
            if case let .messageChunk(_, _, text, _) = event, suppressPendingUserEchoChunk(text, for: sessionId) {
                return
            } else {
                apply(event, to: sessionId)
            }
        case "agent_message_chunk":
            guard !isSuppressingStaleTurnOutput(for: sessionId) else { return }
            refreshWatchdogActivity(for: sessionId)
            markLiveMessageActivity(for: sessionId)
            apply(AgentTranscriptNormalizer.events(from: update), to: sessionId)
        case "session_info_update":
            updateSessionInfo(sessionId: sessionId, object: object)
        case "plan", "tool_call", "tool_call_update", "usage_update":
            guard !isSuppressingStaleTurnOutput(for: sessionId) else { return }
            refreshWatchdogActivity(for: sessionId)
            apply(AgentTranscriptNormalizer.events(from: update), to: sessionId)
        case "config_option_update":
            applyModelConfig(object["configOptions"]?.arrayValue ?? [], sessionId: sessionId)
        case "available_commands_update":
            slashCommands = parseComposerCommands(object["availableCommands"]?.arrayValue ?? [])
        default:
            break
        }
    }

    private func beginTurn(sessionId: String) -> UUID {
        clearActiveTurn(sessionId)
        clearPlanState(for: sessionId)
        completedTurnSessionIds.remove(sessionId)
        refreshDashboardStatus()
        let turnId = UUID()
        activeTurns[sessionId] = ActiveTurn(
            id: turnId,
            generation: clientGenerationByProjectKey[projectKey(forSessionId: sessionId)] ?? 0,
            lastInboundActivity: now()
        )
        activeTurns[sessionId]?.watchdogTask = makeWatchdogTask(sessionId: sessionId, turnId: turnId)
        updateRunningFlags()
        updateCompletionFlags()
        return turnId
    }

    private func reserveTurn(sessionId: String) {
        clearPlanState(for: sessionId)
        completedTurnSessionIds.remove(sessionId)
        refreshDashboardStatus()
        activeTurns[sessionId] = ActiveTurn(
            id: UUID(),
            generation: clientGenerationByProjectKey[projectKey(forSessionId: sessionId)] ?? 0,
            lastInboundActivity: now()
        )
        updateRunningFlags()
        updateCompletionFlags()
    }

    private func clearActiveTurn(_ sessionId: String) {
        activeTurns[sessionId]?.watchdogTask?.cancel()
        activeTurns[sessionId] = nil
    }

    private func isCurrentTurn(sessionId: String, turnId: UUID) -> Bool {
        activeTurns[sessionId]?.id == turnId
    }

    private func drainCurrentTurnEvents(sessionId: String, turnId: UUID) async {
        for _ in 0..<3 where isCurrentTurn(sessionId: sessionId, turnId: turnId) {
            await Task.yield()
        }
    }

    private func makeWatchdogTask(sessionId: String, turnId: UUID) -> Task<Void, Never> {
        let intervalMilliseconds = max(10, min(turnIdleTimeoutMilliseconds / 4, 250))
        return Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(intervalMilliseconds))
                } catch {
                    return
                }
                self?.checkTurnIdleTimeout(sessionId: sessionId, turnId: turnId)
            }
        }
    }

    private func checkTurnIdleTimeout(sessionId: String, turnId: UUID) {
        guard let turn = activeTurns[sessionId], turn.id == turnId else { return }
        if pendingPermissionRequests[sessionId] != nil {
            activeTurns[sessionId]?.lastInboundActivity = now()
            return
        }
        let elapsedMilliseconds = Int(now().timeIntervalSince(turn.lastInboundActivity) * 1000)
        guard elapsedMilliseconds >= turnIdleTimeoutMilliseconds else { return }
        cancelTurn(sessionId: sessionId, reason: .idleTimeout)
    }

    private func refreshWatchdogActivity(for sessionId: String) {
        guard activeTurns[sessionId] != nil else { return }
        activeTurns[sessionId]?.lastInboundActivity = now()
    }

    private func isSuppressingStaleTurnOutput(for sessionId: String) -> Bool {
        staleTurnGenerationBySessionId[sessionId] == clientGenerationByProjectKey[projectKey(forSessionId: sessionId)]
    }

    private func clearStaleSuppressionIfPromptEchoCompleted(for sessionId: String) {
        if pendingUserEchoes[sessionId] == nil {
            staleTurnGenerationBySessionId[sessionId] = nil
        }
    }

    private func cancelTurn(sessionId: String, reason: TurnCancelReason) {
        guard activeTurns[sessionId] != nil || pendingPermissionRequests[sessionId] != nil else { return }
        let request = pendingPermissionRequests[sessionId]
        let key = projectKey(forSessionId: sessionId)
        clearActiveTurn(sessionId)
        pendingPermissionRequests[sessionId] = nil
        queues[sessionId] = nil
        updateRunningFlags()
        updatePermissionFlags()
        completedTurnSessionIds.remove(sessionId)
        updateCompletionFlags()

        switch reason {
        case .manual:
            staleTurnGenerationBySessionId[sessionId] = clientGenerationByProjectKey[key]
            if isActiveProjectKey(key) {
                runtimeMessage = nil
            }
            appendStatus(title: "Cancelled", text: "Agent turn cancelled.", to: sessionId)
        case .idleTimeout:
            let message = "Agent runtime disconnected: turn idle timeout"
            if isActiveProjectKey(key) {
                runtimeMessage = message
            }
            appendError(title: "Turn timed out", text: "Agent turn was idle for \(turnIdleTimeoutMilliseconds) ms and was cancelled.", key: "turn-timeout-\(sessionId)", to: sessionId)
        }

        let client = clients[key]
        Task {
            do {
                try await client?.cancel(sessionId: sessionId)
                if let request {
                    try await client?.cancelPermissionRequest(request.requestId)
                }
                if reason == .idleTimeout {
                    await MainActor.run {
                        cleanupUnhealthyRuntime(message: "Agent runtime disconnected: turn idle timeout", projectKey: key)
                    }
                } else {
                    await MainActor.run {
                        applyDeferredApprovalModeRestartIfNeeded(projectKey: key)
                    }
                }
            } catch {
                await MainActor.run {
                    cleanupUnhealthyRuntime(message: "Agent runtime disconnected: \(userFacingError(error))", projectKey: key)
                }
            }
        }
    }

    private func cleanupUnhealthyRuntime(message: String, projectKey: String) {
        let sessionIdsForProject = sessionProjectKeyBySessionId.filter { $0.value == projectKey }.map(\.key)
        for sessionId in sessionIdsForProject {
            activeTurns[sessionId]?.watchdogTask?.cancel()
            activeTurns[sessionId] = nil
            staleTurnGenerationBySessionId[sessionId] = nil
            pendingPermissionRequests[sessionId] = nil
            completedTurnSessionIds.remove(sessionId)
        }
        updateRunningFlags()
        updatePermissionFlags()
        updateCompletionFlags()
        pendingApprovalModeRestartProjectKeys.remove(projectKey)
        primingSessionIdByProjectKey[projectKey] = nil
        clientGenerationByProjectKey[projectKey, default: 0] += 1
        eventTasksByProjectKey[projectKey]?.cancel()
        eventTasksByProjectKey[projectKey] = nil
        clients[projectKey]?.terminate()
        clients[projectKey] = nil
        if isActiveProjectKey(projectKey) {
            availability = .disconnected(message)
            runtimeMessage = message
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
                isRunning: activeTurns[sessionId] != nil,
                isAwaitingPermission: pendingPermissionRequests[sessionId] != nil,
                hasCompletedTurn: completedTurnSessionIds.contains(sessionId)
            ))
        }
        sortSessions()
    }

    private func row(from summary: AcpSessionSummary, projectKey: String) -> AgentSessionRow {
        if let cwd = summary.cwd {
            let normalized = RecentProjectStore.normalizedPath(cwd)
            sessionCwdBySessionId[summary.sessionId] = normalized
            sessionProjectPathBySessionId[summary.sessionId] = recentProjectPaths.contains(normalized) ? normalized : nil
        }
        sessionProjectKeyBySessionId[summary.sessionId] = projectKey
        return AgentSessionRow(
            sessionId: summary.sessionId,
            title: summary.title?.nonEmpty ?? summary.sessionId,
            detail: folderDetail(summary.cwd),
            updatedAt: summary.updatedAt.flatMap(parseDate),
            observedAt: nil,
            isRunning: activeTurns[summary.sessionId] != nil,
            isAwaitingPermission: pendingPermissionRequests[summary.sessionId] != nil,
            hasCompletedTurn: completedTurnSessionIds.contains(summary.sessionId)
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
            sessions[index].isRunning = activeTurns[sessions[index].sessionId] != nil
        }
    }

    private func updatePermissionFlags() {
        for index in sessions.indices {
            sessions[index].isAwaitingPermission = pendingPermissionRequests[sessions[index].sessionId] != nil
        }
    }

    private func updateCompletionState(sessionId: String, stopReason: String) {
        if stopReason == "end_turn" {
            completedTurnSessionIds.insert(sessionId)
        } else {
            completedTurnSessionIds.remove(sessionId)
        }
        updateCompletionFlags()
    }

    private func updateCompletionFlags() {
        for index in sessions.indices {
            sessions[index].hasCompletedTurn = completedTurnSessionIds.contains(sessions[index].sessionId)
        }
    }

    private func ensureSessionRowExists(for sessionId: String) {
        guard sessions.contains(where: { $0.sessionId == sessionId }) == false else { return }
        upsert(.init(
            sessionId: sessionId,
            title: sessionId,
            detail: "Session",
            observedAt: now(),
            isRunning: activeTurns[sessionId] != nil,
            isAwaitingPermission: pendingPermissionRequests[sessionId] != nil,
            hasCompletedTurn: completedTurnSessionIds.contains(sessionId)
        ))
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
        if sessionId == activeSessionId {
            updateDashboardReferences()
        }
    }

    private func clearPlanState(for sessionId: String) {
        guard var state = transcriptStates[sessionId] else { return }
        state.plan = nil
        transcriptStates[sessionId] = state
    }

    private func reconcileSessionProjectPaths() {
        for (sessionId, cwd) in sessionCwdBySessionId {
            sessionProjectPathBySessionId[sessionId] = recentProjectPaths.contains(cwd) ? cwd : nil
        }
    }

    private func updateActiveProjectPathFromSession() {
        let nextPath = activeSessionId.flatMap { sessionProjectPathBySessionId[$0] }
        guard nextPath != activeSessionProjectPath else {
            updateDashboardReferences()
            return
        }
        activeSessionProjectPath = nextPath
        dashboardRefreshGeneration += 1
        if let nextPath {
            dashboardState = ProjectDashboardState(
                projectPath: nextPath,
                references: activeReferences,
                isRefreshing: true
            )
            refreshDashboardStatus()
        } else {
            dashboardState = nil
        }
    }

    private func refreshDashboardStatus() {
        guard let projectPath = activeSessionProjectPath else {
            dashboardState = nil
            dashboardRefreshGeneration += 1
            return
        }
        let generation = dashboardRefreshGeneration + 1
        dashboardRefreshGeneration = generation
        dashboardState = ProjectDashboardState(
            projectPath: projectPath,
            gitStatus: dashboardState?.projectPath == projectPath ? dashboardState?.gitStatus ?? .unavailable() : .unavailable(),
            references: activeReferences,
            isRefreshing: true
        )
        Task {
            let status = await gitStatusProvider(projectPath)
            guard activeSessionProjectPath == projectPath, dashboardRefreshGeneration == generation else { return }
            dashboardState = ProjectDashboardState(
                projectPath: projectPath,
                gitStatus: status,
                references: activeReferences,
                isRefreshing: false
            )
        }
    }

    private func updateDashboardReferences() {
        guard let current = dashboardState else { return }
        dashboardState = ProjectDashboardState(
            projectPath: current.projectPath,
            gitStatus: current.gitStatus,
            references: activeReferences,
            isRefreshing: current.isRefreshing
        )
    }

    private static func fileReference(_ reference: AgentReference, isInside projectPath: String) -> Bool {
        let referencePath: String?
        if let url = URL(string: reference.uri), url.isFileURL {
            referencePath = url.standardizedFileURL.path
        } else if reference.uri.hasPrefix("/") {
            referencePath = URL(fileURLWithPath: reference.uri).standardizedFileURL.path
        } else {
            referencePath = nil
        }
        guard let referencePath else { return false }
        let root = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        return referencePath == root || referencePath.hasPrefix(root + "/")
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

    var currentSlashTokenRange: Range<String.Index>? {
        guard let slashIndex = lastIndex(of: "/") else { return nil }
        let token = self[slashIndex...]
        guard token.dropFirst().allSatisfy({ !$0.isWhitespace }) else { return nil }
        if slashIndex > startIndex {
            let previous = index(before: slashIndex)
            guard self[previous].isWhitespace else { return nil }
        }
        return slashIndex..<endIndex
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }
}
