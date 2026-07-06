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
    private(set) var runtimeMessage: String?
    private(set) var modelOptions: [ComposerModelOption] = []
    private(set) var slashCommands: [ComposerCommand] = []
    private(set) var sessionModelSaveInFlight = false
    private(set) var approvalMode: ApprovalMode
    private(set) var pendingPermissionRequests: [String: PermissionRequest] = [:]
    private(set) var reviewState = ProjectReviewPaneState()

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
    /// Sessions the user has deleted locally. The ACP server is not
    /// guaranteed to agree — real Devin doesn't implement `session/delete`
    /// at all — so once hidden, a session must never reappear from a later
    /// `session/update`, even across a relaunch. Our local session list is
    /// not required to stay consistent with the backend's.
    private var hiddenSessionIds: Set<String> = []
    private var pendingUserEchoes: [String: [String]] = [:]
    private var currentModelBySessionId: [String: String] = [:]
    private var pendingModelBySessionId: [String: String] = [:]
    private var persistedNewChatModelByBackend: [AgentBackendKind: String] = [:]
    private var defaultModelId: String?
    private var dashboardRefreshGeneration = 0
    private var reviewRefreshGeneration = 0
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
    /// Sessions whose server-side context (history, config) is already
    /// known to the *current* process for their project — either because
    /// they were created/primed this run (`createSessionAndSend`,
    /// `primeComposerSession`), or because `send(_:to:isAlreadyMarkedRunning:)`
    /// already primed them with `session/load` earlier this run. Selecting
    /// a session never touches this; only sending to it does. Cleared
    /// per-project whenever that project's client is torn down (see
    /// `terminateClient`/`cleanupUnhealthyRuntime`) since a freshly spawned
    /// process has no live context for any session, even one primed before
    /// the restart.
    private var primedSessionIds: [String: Set<String>] = [:]
    /// Sessions currently inside a send-time `session/load` prime call.
    /// `handleSessionUpdate` drops any `session/update` for a session in
    /// this set unconditionally: priming is a context-loading side effect,
    /// not a way to repaint the transcript, so its replay must never reach
    /// the UI or the durable transcript cache.
    private var suppressingPrimeReplayForSessionIds: Set<String> = []
    private let backendKind: AgentBackendKind
    private let makeClient: @Sendable () throws -> AgentSessionClient
    private let makeProjectClient: (@Sendable (String, ApprovalMode) throws -> AgentSessionClient)?
    private let approvalModePreferenceStore: ApprovalModePreferenceStore
    private let persistenceStore: SessionPersistenceStore?
    private let gitStatusProvider: @Sendable (String) async -> ProjectGitStatus
    private let reviewSnapshotProvider: @Sendable (String) async -> ProjectReviewSnapshot
    private let reviewPreviewProvider: @Sendable (String, ProjectChangedFile) async -> ProjectFilePreview
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
        persistenceStore: SessionPersistenceStore? = nil,
        gitStatusProvider: @escaping @Sendable (String) async -> ProjectGitStatus = { cwd in
            await ProjectGitStatusService().status(cwd: cwd)
        },
        reviewSnapshotProvider: @escaping @Sendable (String) async -> ProjectReviewSnapshot = { cwd in
            await ProjectReviewService().snapshot(cwd: cwd)
        },
        reviewPreviewProvider: @escaping @Sendable (String, ProjectChangedFile) async -> ProjectFilePreview = { cwd, file in
            await ProjectReviewService().preview(cwd: cwd, file: file)
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
        self.persistenceStore = persistenceStore
        if let persistenceStore, let hiddenIds = try? persistenceStore.hiddenSessionIds() {
            self.hiddenSessionIds = hiddenIds
        }
        self.gitStatusProvider = gitStatusProvider
        self.reviewSnapshotProvider = reviewSnapshotProvider
        self.reviewPreviewProvider = reviewPreviewProvider
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
        selector: AgentBackendSelector = AgentBackendSelector(),
        persistenceStore: SessionPersistenceStore? = nil
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
            persistenceStore: persistenceStore,
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

    var isReviewAvailable: Bool {
        reviewProjectPath != nil
    }

    var reviewProjectPath: String? {
        activeSessionProjectPath ?? (isNewSession ? selectedProjectPath : nil)
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
        hydrateAllPersistedSessions()
        let key = currentSidebarProjectKey
        Task {
            await ensureConnected(projectKey: key)
            if isNewSession {
                await primeComposerSession(forProjectKey: key)
            }
        }
    }

    /// Loads every durably cached session row, across every project, into
    /// the sidebar. The sidebar is a single global list of every session
    /// this app has ever sent into: it is independent of whichever project
    /// is currently selected for the *next* new chat, so selecting a
    /// different project only changes where a new session would be
    /// created, never which existing sessions are visible. This is also the
    /// sidebar's only source of session discovery: there is no backend
    /// `session/list` call anywhere in this app, so a session this app
    /// never sent through (another client, another machine, or one lost to
    /// a crash before its first persisted write) is permanently invisible
    /// here. `upsert` is still the write-through every live update goes
    /// through afterward, so those rows stay current as the session is used.
    private func hydrateAllPersistedSessions() {
        guard let persistenceStore else { return }
        guard let rows = try? persistenceStore.listAllSessionRows() else { return }
        for row in rows {
            sessionProjectKeyBySessionId[row.sessionId] = row.projectKey
            // For Devin, a project's own key *is* its normalized cwd (see
            // `projectKey(for:)`), so a persisted row can still be
            // recognized as project-backed after a relaunch even though
            // nothing in `sessions` durably stores cwd separately. Mock's
            // shared project key never matches a real recent path, so this
            // is always a no-op there. Recorded unconditionally (mirroring
            // the pre-`session/list`-removal behavior) rather than gated on
            // `recentProjectPaths` here: `recentProjectPaths` may not be
            // current yet at hydration time (e.g. `ContentView.selectProject`
            // hydrates before its own `loadRecentProjects` call resolves),
            // so `reconcileSessionProjectPaths()` — called whenever
            // `setRecentProjects` runs, including after that reload — is
            // what actually decides eligibility from `sessionCwdBySessionId`.
            sessionCwdBySessionId[row.sessionId] = row.projectKey
            sessionProjectPathBySessionId[row.sessionId] = recentProjectPaths.contains(row.projectKey) ? row.projectKey : nil
            upsert(AgentSessionRow(
                sessionId: row.sessionId,
                title: row.title,
                detail: row.detail,
                updatedAt: row.providerUpdatedAt.map(Date.init(timeIntervalSince1970:)),
                observedAt: row.observedAt.map(Date.init(timeIntervalSince1970:)),
                isRunning: false,
                isAwaitingPermission: false,
                hasCompletedTurn: false
            ))
        }
    }

    func startNewChat() {
        let previousReviewPath = reviewProjectPath
        saveActiveDraft()
        activeSessionId = nil
        activeSessionProjectPath = nil
        dashboardState = nil
        dashboardRefreshGeneration += 1
        draft.clearAfterSend()
        applyNewChatPersistedModel()
        reconcileReviewContext(previousPath: previousReviewPath)
    }

    func setRecentProjects(_ projects: [RecentProject]) {
        recentProjectPaths = Set(projects.map { RecentProjectStore.normalizedPath($0.path) })
        reconcileSessionProjectPaths()
        updateActiveProjectPathFromSession()
    }

    func selectProject(_ project: RecentProject) {
        guard isProjectSelectionAvailable else { return }
        let previousReviewPath = reviewProjectPath
        selectedProject = project
        reconcileReviewContext(previousPath: previousReviewPath)
        connectAndPrimeComposerSessionForSelectedProjectIfNeeded()
    }

    func clearSelectedProject() {
        guard isProjectSelectionAvailable else { return }
        let previousReviewPath = reviewProjectPath
        selectedProject = nil
        reconcileReviewContext(previousPath: previousReviewPath)
        connectAndPrimeComposerSessionForSelectedProjectIfNeeded()
    }

    func openReview() {
        guard isReviewAvailable else { return }
        reviewState.isOpen = true
        refreshReview()
    }

    func closeReview() {
        reviewState.isOpen = false
    }

    func refreshReview() {
        refreshReviewSnapshot()
    }

    func loadReviewPreview(_ file: ProjectChangedFile) {
        loadReviewPreview(for: file)
    }

    /// Devin spawns one process per project, so switching the "new chat"
    /// project needs its own live agent connection readied ahead of time
    /// (see `primeComposerSession`). The sidebar itself is already a global
    /// list hydrated once up front (see `hydrateAllPersistedSessions`), but
    /// re-hydrating here too is a cheap, idempotent way to pick up any rows
    /// written since (e.g. this same project's own earlier session, if this
    /// method runs before `start()` has). Mock has a single shared
    /// server/project key that's already connected up front, so this is a
    /// no-op there.
    private func connectAndPrimeComposerSessionForSelectedProjectIfNeeded() {
        guard backendKind == .devin, isNewSession else { return }
        let key = projectKey(for: selectedProjectPath)
        hydrateAllPersistedSessions()
        if clients[key] != nil {
            // A different project may have left a stale in-flight status
            // message (e.g. "Sending...") behind when it lost the
            // foreground to this one; an already-connected project's own
            // true status is simply healthy, so reflect that immediately
            // rather than waiting on a no-op `ensureConnected` to do it.
            availability = .available
            runtimeMessage = nil
        }
        Task {
            await ensureConnected(projectKey: key)
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
    /// user switches projects before sending) costs nothing and never
    /// appears anywhere this app could discover it.
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
            markSessionPrimed(sessionId, projectKey: key)
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
        primedSessionIds[key] = nil
        // A prime in flight for one of this project's sessions is now
        // talking to a dead client; its eventual timeout/failure would
        // clear this anyway, but there's no reason to keep a legitimate
        // future prime (after reconnect) needlessly suppressed until then.
        suppressingPrimeReplayForSessionIds.subtract(sessionIds(forProjectKey: key))
    }

    private func sessionIds(forProjectKey key: String) -> [String] {
        sessionProjectKeyBySessionId.filter { $0.value == key }.map(\.key)
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
        followTailBySessionId[activeSessionId] = followsTail
    }

    /// Selecting a session is pure retrieval: it never talks to the agent
    /// runtime. The durably cached transcript paints immediately from
    /// SQLite and that's the whole operation — no `session/load`, no
    /// `ensureConnected`. Server-side context is only fetched lazily, the
    /// moment the user actually sends into this session (see
    /// `primeSessionForSend`), so an idle sidebar never causes network or
    /// process activity.
    func selectSession(_ sessionId: String) {
        saveActiveDraft()
        activeSessionId = sessionId
        updateActiveProjectPathFromSession()
        ensureSessionRowExists(for: sessionId)
        restoreDraft(for: sessionId)
        if followTailBySessionId[sessionId] == nil {
            followTailBySessionId[sessionId] = true
        }
        hydrateTranscriptFromCacheIfNeeded(sessionId)
    }

    /// Paints the durably cached transcript for `sessionId` immediately, if
    /// there is one and nothing is already in memory for it (a session
    /// visited earlier in this process run already reflects at least as
    /// much as the on-disk cache, since writes flow from `apply(_:to:)` as
    /// they happen).
    private func hydrateTranscriptFromCacheIfNeeded(_ sessionId: String) {
        guard transcriptStates[sessionId] == nil else { return }
        guard let persistenceStore else { return }
        var state = AgentTranscriptState()
        if let items = try? persistenceStore.fetchTranscriptItems(sessionId: sessionId) {
            for persistedItem in items {
                if let item = TranscriptPersistenceCoding.decode(persistedItem) {
                    state.items.append(item)
                }
            }
        }
        if let persistedState = try? persistenceStore.fetchTranscriptState(sessionId: sessionId) {
            TranscriptPersistenceCoding.apply(persistedState, to: &state)
        }
        transcriptStates[sessionId] = state
    }

    /// Deletes `sessionId` from the sidebar. The ACP `session/delete` call is
    /// best-effort only: some backends (real Devin, notably) don't
    /// implement it at all ("Method not found"), so our local session list
    /// is not required to stay consistent with whatever the server still
    /// reports. Local removal (and the durable hidden-session marker that
    /// keeps it from reappearing) happens unconditionally, regardless of
    /// whether the remote call succeeds, fails, or the backend is
    /// unreachable.
    func deleteSession(_ sessionId: String) {
        let key = projectKey(forSessionId: sessionId)
        Task {
            if await ensureConnected(projectKey: key), let client = clients[key] {
                try? await client.deleteSession(sessionId: sessionId)
            }
            removeSessionLocally(sessionId)
        }
    }

    private func removeSessionLocally(_ sessionId: String) {
        if let key = sessionProjectKeyBySessionId[sessionId] {
            primedSessionIds[key]?.remove(sessionId)
        }
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
        hiddenSessionIds.insert(sessionId)
        try? persistenceStore?.deleteSession(sessionId: sessionId)
        try? persistenceStore?.markSessionHidden(sessionId: sessionId, hiddenAt: now().timeIntervalSince1970)
        if activeSessionId == sessionId {
            activeSessionId = nil
            activeSessionProjectPath = nil
            dashboardState = nil
            dashboardRefreshGeneration += 1
            draft.clearAfterSend()
            applyNewChatPersistedModel()
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
            markSessionPrimed(sessionId, projectKey: key)
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
        if !isSessionPrimed(sessionId, projectKey: key) {
            guard await primeSessionForSend(sessionId, projectKey: key, client: client) else {
                if isAlreadyMarkedRunning {
                    clearActiveTurn(sessionId)
                    updateRunningFlags()
                }
                return
            }
        }
        let displayMessage = snapshot.previewText
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
        refreshReviewCountsIfSupported()
        applyDeferredApprovalModeRestartIfNeeded(projectKey: key)
        await startNextQueuedPromptIfNeeded(for: sessionId)
    }

    private func isSessionPrimed(_ sessionId: String, projectKey key: String) -> Bool {
        primedSessionIds[key]?.contains(sessionId) ?? false
    }

    private func markSessionPrimed(_ sessionId: String, projectKey key: String) {
        primedSessionIds[key, default: []].insert(sessionId)
    }

    /// Loads `sessionId`'s server-side context into the current process via
    /// `session/load`, the first time this run it's about to receive a
    /// prompt. This is the only remaining caller of `session/load`: it's a
    /// context-priming call, not a way to repaint the transcript, so any
    /// `session/update` replay it triggers is fully suppressed (see
    /// `suppressingPrimeReplayForSessionIds`) rather than applied. Returns
    /// `false` on failure, in which case the caller must abort the send —
    /// appending an optimistic user row or starting a turn against a
    /// session the backend couldn't load would show a phantom sent message.
    private func primeSessionForSend(_ sessionId: String, projectKey key: String, client: AgentSessionClient) async -> Bool {
        suppressingPrimeReplayForSessionIds.insert(sessionId)
        do {
            let result = try await client.loadSession(sessionId: sessionId, cwd: nil)
            sessionProjectKeyBySessionId[sessionId] = key
            applyModelConfig(result.configOptions, sessionId: sessionId)
            await refreshSessionSlashCommands(sessionId, projectKey: key)
            // A few yields let any replay notifications the load triggered
            // as a side effect actually arrive and get dropped by
            // `handleSessionUpdate` before suppression lifts.
            for _ in 0..<3 {
                await Task.yield()
            }
            suppressingPrimeReplayForSessionIds.remove(sessionId)
            markSessionPrimed(sessionId, projectKey: key)
            return true
        } catch {
            suppressingPrimeReplayForSessionIds.remove(sessionId)
            appendError(title: "Load failed", text: "Failed to load session: \(error)", key: "load-failed", to: sessionId)
            return false
        }
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
            guard AcpRuntimeLogLine.isWorthRecording(line) else { return }
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
        // `session/load` is now a silent context-priming call (see
        // `primeSessionForSend`), not a way to repaint the transcript: any
        // replay it triggers as a side effect must never reach the UI or
        // the durable transcript cache.
        guard !suppressingPrimeReplayForSessionIds.contains(sessionId) else { return }
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
            markObservedActivity(for: sessionId)
            if case let .messageChunk(_, _, text, _) = event, suppressPendingUserEchoChunk(text, for: sessionId) {
                return
            } else {
                apply(event, to: sessionId)
            }
        case "agent_message_chunk":
            guard !isSuppressingStaleTurnOutput(for: sessionId) else { return }
            refreshWatchdogActivity(for: sessionId)
            markObservedActivity(for: sessionId)
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
        refreshReviewCountsIfSupported()

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
        let sessionIdsForProject = sessionIds(forProjectKey: projectKey)
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
        refreshReviewCountsIfSupported()
        pendingApprovalModeRestartProjectKeys.remove(projectKey)
        primingSessionIdByProjectKey[projectKey] = nil
        primedSessionIds[projectKey] = nil
        // See `terminateClient`: don't leave a dead client's in-flight prime
        // suppressing replay for a session that could be primed again after
        // reconnecting.
        suppressingPrimeReplayForSessionIds.subtract(sessionIdsForProject)
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
            persistSessionRow(sessions[index])
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

    /// The single choke point every sidebar-row mutation goes through
    /// (`updateSessionInfo`, `ensureSessionRowExists`, cold-start
    /// hydration). Guarding here — rather than at each call site — is what
    /// keeps a locally deleted session from reappearing no matter which
    /// path (a background `session/update`, a lingering permission
    /// request) tries to add it back.
    private func upsert(_ row: AgentSessionRow) {
        guard !hiddenSessionIds.contains(row.sessionId) else { return }
        if let index = sessions.firstIndex(where: { $0.sessionId == row.sessionId }) {
            sessions[index] = row
        } else {
            sessions.insert(row, at: 0)
        }
        sortSessions()
        persistSessionRow(row)
    }

    private func sortSessions() {
        sessions.sort { left, right in
            (left.observedAt ?? left.updatedAt ?? .distantPast) > (right.observedAt ?? right.updatedAt ?? .distantPast)
        }
    }

    /// Write-through for durable session fields (`title`, `detail`,
    /// `updatedAt`, `observedAt`). Live turn-state (`isRunning`,
    /// `isAwaitingPermission`, `hasCompletedTurn`) is intentionally not
    /// part of `PersistedSessionRow` and correctly resets after a relaunch.
    private func persistSessionRow(_ row: AgentSessionRow) {
        guard let persistenceStore else { return }
        let persisted = PersistedSessionRow(
            sessionId: row.sessionId,
            projectKey: sessionProjectKeyBySessionId[row.sessionId] ?? projectKey(for: selectedProjectPath),
            backend: backendKind.persistedIdentifier,
            title: row.title,
            detail: row.detail,
            providerUpdatedAt: row.updatedAt?.timeIntervalSince1970,
            observedAt: row.observedAt?.timeIntervalSince1970,
            createdAt: now().timeIntervalSince1970
        )
        try? persistenceStore.upsertSessionRow(persisted)
    }

    private func markObservedActivity(for sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        sessions[index].observedAt = now()
        sortSessions()
        persistSessionRow(sessions[index])
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
        persistTranscriptChange(event, sessionId: sessionId, state: state)
    }

    /// Writes only the 1-2 rows `event` actually changed, off the main
    /// actor. No debounce: each `apply(_:to:)` call already touches at most
    /// one transcript item plus (rarely) the singleton state row, so a
    /// wall-clock debounce would add complexity (an injectable clock, a
    /// termination-flush path — this app has no `AppDelegate` today) for no
    /// real benefit. Revisit if profiling ever shows write volume matters
    /// at fast token-streaming rates.
    private func persistTranscriptChange(_ event: AgentTranscriptEvent, sessionId: String, state: AgentTranscriptState) {
        guard let persistenceStore else { return }
        let changedItems = Self.changedItemIds(for: event, resultingState: state)
            .compactMap { id in state.items.first { $0.id == id } }
            .compactMap(TranscriptPersistenceCoding.encode)
        let persistedState = Self.eventTouchesSingletonState(event) ? TranscriptPersistenceCoding.encodeState(state) : nil
        guard !changedItems.isEmpty || persistedState != nil else { return }
        Task.detached(priority: .utility) {
            if !changedItems.isEmpty {
                try? persistenceStore.upsertTranscriptItems(sessionId: sessionId, items: changedItems)
            }
            if let persistedState {
                try? persistenceStore.upsertTranscriptState(sessionId: sessionId, state: persistedState)
            }
        }
    }

    /// The transcript item id(s) `event` touched in `resultingState`
    /// (post-`apply`), without duplicating `AgentTranscriptReducer`'s
    /// private id-assignment logic: ids driven by an explicit
    /// `messageId`/`toolCallId`/`replacementKey` are deterministic, and the
    /// reducer's only two "no explicit id" paths (message merge/append with
    /// no `messageId`, status/error append with no `replacementKey`) always
    /// land on the trailing item.
    private static func changedItemIds(for event: AgentTranscriptEvent, resultingState state: AgentTranscriptState) -> [String] {
        switch event {
        case let .messageChunk(_, messageId, _, _):
            if let messageId { return ["message-\(messageId)"] }
            return state.items.last.map { [$0.id] } ?? []
        case let .tool(toolCallId, _, _, _, _):
            return ["tool-\(toolCallId)"]
        case let .toolExpansion(toolCallId, _):
            return ["tool-\(toolCallId)"]
        case let .status(_, _, replacementKey):
            if let replacementKey { return ["status-\(replacementKey)"] }
            return state.items.last.map { [$0.id] } ?? []
        case let .error(_, _, replacementKey):
            if let replacementKey { return ["error-\(replacementKey)"] }
            return state.items.last.map { [$0.id] } ?? []
        case let .stopReason(reason):
            let id = "status-stop-\(reason)"
            return state.items.contains { $0.id == id } ? [id] : []
        case .plan, .usage, .references:
            return []
        }
    }

    private static func eventTouchesSingletonState(_ event: AgentTranscriptEvent) -> Bool {
        switch event {
        case .plan, .usage, .references, .stopReason:
            true
        case .messageChunk, .tool, .toolExpansion, .status, .error:
            false
        }
    }

    private func clearPlanState(for sessionId: String) {
        guard var state = transcriptStates[sessionId] else { return }
        state.plan = nil
        transcriptStates[sessionId] = state
        guard let persistenceStore else { return }
        let persistedState = TranscriptPersistenceCoding.encodeState(state)
        Task.detached(priority: .utility) {
            try? persistenceStore.upsertTranscriptState(sessionId: sessionId, state: persistedState)
        }
    }

    private func reconcileSessionProjectPaths() {
        for (sessionId, cwd) in sessionCwdBySessionId {
            sessionProjectPathBySessionId[sessionId] = recentProjectPaths.contains(cwd) ? cwd : nil
        }
    }

    private func updateActiveProjectPathFromSession() {
        let previousReviewPath = reviewProjectPath
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
        reconcileReviewContext(previousPath: previousReviewPath)
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

    private func refreshReviewSnapshot() {
        guard let projectPath = reviewProjectPath else {
            reviewRefreshGeneration += 1
            reviewState = ProjectReviewPaneState()
            return
        }
        let generation = reviewRefreshGeneration + 1
        reviewRefreshGeneration = generation
        reviewState.projectPath = projectPath
        reviewState.isRefreshing = true
        Task {
            let snapshot = await reviewSnapshotProvider(projectPath)
            guard reviewProjectPath == projectPath, reviewRefreshGeneration == generation else { return }
            reviewState.snapshot = snapshot
            reviewState.isRefreshing = false
            reviewState.previewCache = [:]
            reviewState.loadingPreviewFileIDs = []
        }
    }

    private func refreshReviewCountsIfSupported() {
        guard reviewProjectPath != nil else { return }
        refreshReviewSnapshot()
    }

    private func loadReviewPreview(for file: ProjectChangedFile) {
        guard let projectPath = reviewProjectPath else { return }
        let generation = reviewRefreshGeneration
        let cacheKey = file.id
        if reviewState.previewCache[cacheKey] != nil || reviewState.loadingPreviewFileIDs.contains(cacheKey) { return }
        reviewState.loadingPreviewFileIDs.insert(cacheKey)
        Task {
            let preview = await reviewPreviewProvider(projectPath, file)
            guard reviewProjectPath == projectPath, reviewRefreshGeneration == generation else { return }
            reviewState.previewCache[cacheKey] = preview
            reviewState.loadingPreviewFileIDs.remove(cacheKey)
        }
    }

    private func reconcileReviewContext(previousPath: String?) {
        let currentPath = reviewProjectPath
        guard previousPath != currentPath else { return }
        reviewRefreshGeneration += 1
        reviewState = ProjectReviewPaneState()
        if currentPath != nil {
            refreshReviewCountsIfSupported()
        }
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
