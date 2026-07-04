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
    private(set) var nextCursor: String?
    private(set) var runtimeMessage: String?
    private(set) var modelOptions: [ComposerModelOption] = []
    private(set) var slashCommands: [ComposerCommand] = []
    private(set) var sessionModelSaveInFlight = false
    private(set) var approvalMode: ApprovalMode
    private(set) var pendingPermissionRequests: [String: PermissionRequest] = [:]

    private var transcriptStates: [String: AgentTranscriptState] = [:]
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
    private var client: AgentSessionClient?
    private var clientGeneration = 0
    private var connectionTask: Task<Bool, Never>?
    private var eventTask: Task<Void, Never>?
    private let backendKind: AgentBackendKind
    private let makeClient: @Sendable () throws -> AgentSessionClient
    private let approvalModePreferenceStore: ApprovalModePreferenceStore
    private let now: @Sendable () -> Date
    private let turnIdleTimeoutMilliseconds: Int
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
        approvalModePreferenceStore: ApprovalModePreferenceStore = .userDefaults,
        now: @escaping @Sendable () -> Date = Date.init,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        turnIdleTimeoutMilliseconds: Int? = nil
    ) {
        self.backendKind = backendKind
        self.makeClient = makeClient
        self.approvalModePreferenceStore = approvalModePreferenceStore
        approvalMode = approvalModePreferenceStore.load(backendKind)
        self.now = now
        self.homeDirectoryPath = homeDirectoryPath
        self.turnIdleTimeoutMilliseconds = turnIdleTimeoutMilliseconds
            ?? ProcessInfo.processInfo.environment["LEVEL5_ACP_TURN_IDLE_TIMEOUT_MS"].flatMap(Int.init)
            ?? 120_000
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

    var canSendWithButton: Bool {
        canEditComposer
            && !isActiveSessionRunning
            && !draft.isEmpty
    }

    var canEditComposer: Bool {
        guard activePermissionRequest == nil else { return false }
        return switch backendKind {
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
        saveActiveDraft()
        activeSessionId = nil
        draft.clearAfterSend()
        applyNewChatPersistedModel()
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
        let snapshot = draft
        guard !snapshot.isEmpty else {
            draft.clearAfterSend()
            return
        }
        guard case .acpMock = backendKind else {
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
        let previous = currentModelBySessionId[sessionId] ?? defaultModelId
        currentModelBySessionId[sessionId] = modelId
        draft.selectedModelId = modelId
        pendingModelBySessionId[sessionId] = modelId
        sessionModelSaveInFlight = true
        Task {
            guard await ensureConnected(), let client else {
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
        approvalMode = mode
        approvalModePreferenceStore.save(mode, backendKind)
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
        ensureSessionRowExists(for: sessionId)
        restoreDraft(for: sessionId)
        if followTailBySessionId[sessionId] == nil {
            followTailBySessionId[sessionId] = true
        }
        Task {
            guard await ensureConnected() else { return }
            guard let client else { return }
            transcriptStates[sessionId] = AgentTranscriptState()
            loadingSessionIds.insert(sessionId)
            do {
                let result = try await client.loadSession(sessionId: sessionId, cwd: nil)
                applyModelConfig(result.configOptions, sessionId: sessionId)
                await refreshSessionSlashCommands(sessionId)
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
                draftsBySessionId[sessionId] = nil
                followTailBySessionId[sessionId] = nil
                pendingPermissionRequests[sessionId] = nil
                completedTurnSessionIds.remove(sessionId)
                activeTurns[sessionId]?.watchdogTask?.cancel()
                activeTurns[sessionId] = nil
                if activeSessionId == sessionId {
                    activeSessionId = nil
                    draft.clearAfterSend()
                    applyNewChatPersistedModel()
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
                clientGeneration += 1
                startEventTask(client.events, generation: clientGeneration)
                try await client.initialize()
                await refreshGlobalComposerDiscovery()
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

    private func refreshGlobalComposerDiscovery() async {
        guard let client else { return }
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

    private func refreshSessionSlashCommands(_ sessionId: String) async {
        guard let client else { return }
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
            applyModelConfig(result.configOptions, sessionId: sessionId)
            await refreshSessionSlashCommands(sessionId)
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
            activeSessionId = nil
            let message = "Agent runtime disconnected: \(userFacingError(error))"
            availability = .disconnected(message)
            runtimeMessage = message
        }
    }

    private func send(_ snapshot: ComposerDraft, to sessionId: String, isAlreadyMarkedRunning: Bool = false) async {
        guard await ensureConnected() else {
            if isAlreadyMarkedRunning {
                clearActiveTurn(sessionId)
                updateRunningFlags()
            }
            return
        }
        guard let client else { return }
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
            runtimeMessage = nil
            apply(.stopReason(result.stopReason), to: sessionId)
            updateCompletionState(sessionId: sessionId, stopReason: result.stopReason)
            await drainCurrentTurnEvents(sessionId: sessionId, turnId: turnId)
        } catch {
            guard isCurrentTurn(sessionId: sessionId, turnId: turnId) else { return }
            if case .processExited = error as? AcpTransportError {
                cleanupUnhealthyRuntime(message: "Agent runtime disconnected: \(userFacingError(error))")
            }
            appendError(title: "Prompt failed", text: "Prompt failed: \(error)", key: "prompt-failed-\(displayMessage)", to: sessionId)
            completedTurnSessionIds.remove(sessionId)
            updateCompletionFlags()
            removePendingUserEcho(displayMessage, for: sessionId)
            await drainCurrentTurnEvents(sessionId: sessionId, turnId: turnId)
        }
        guard isCurrentTurn(sessionId: sessionId, turnId: turnId) else { return }
        clearActiveTurn(sessionId)
        updateRunningFlags()
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

    private func startEventTask(_ events: AsyncStream<AcpEvent>, generation: Int) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, generation: generation)
            }
        }
    }

    private func handle(_ event: AcpEvent, generation: Int) async {
        guard generation == clientGeneration else { return }
        switch event {
        case let .notification(method, params):
            guard method == AcpMethod.sessionUpdate, let params else { return }
            handleSessionUpdate(params, generation: generation)
        case let .serverRequest(id, method, params):
            if method == AcpMethod.sessionRequestPermission {
                await handlePermissionRequest(id: id, params: params)
            }
        case let .diagnostic(diagnostic):
            appendStatus(title: "Diagnostic", text: diagnostic.message, to: activeSessionId)
        case let .stderr(line):
            appendStatus(title: "Runtime stderr", text: line, to: activeSessionId)
        case let .processExit(exit):
            let message = "Agent runtime disconnected: status \(exit.status)"
            let activeSessionIds = Array(activeTurns.keys)
            cleanupUnhealthyRuntime(message: message)
            for sessionId in activeSessionIds {
                appendError(title: "Runtime exited", text: "Agent runtime exited with status \(exit.status).", key: "process-exit-\(exit.status)-\(sessionId)", to: sessionId)
            }
        case .activity:
            break
        }
    }

    private func handlePermissionRequest(id: AcpRpcID, params: JSONValue?) async {
        guard let request = PermissionRequest.parse(requestId: id, params: params) else {
            runtimeMessage = "Permission request could not be read."
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
                runtimeMessage = "Permission request had no available options."
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
                runtimeMessage = "Permission request had no available options."
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
        do {
            try await client?.respondToPermissionRequest(.init(
                requestId: request.requestId,
                optionId: optionId,
                localInstructionText: localInstructionText
            ))
            pendingPermissionRequests[request.sessionId] = nil
            updatePermissionFlags()
            refreshWatchdogActivity(for: request.sessionId)
            runtimeMessage = nil
            if let followUpInstruction {
                enqueueOrSendInstruction(followUpInstruction, for: request.sessionId)
            }
        } catch {
            pendingPermissionRequests[request.sessionId] = nil
            updatePermissionFlags()
            refreshWatchdogActivity(for: request.sessionId)
            runtimeMessage = "Permission response failed: \(userFacingError(error))"
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

    private func handleSessionUpdate(_ params: JSONValue, generation: Int) {
        guard let update = try? AcpProtocolCoding.decode(AcpSessionUpdate.self, from: params) else { return }
        let sessionId = update.sessionId
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
        default:
            break
        }
    }

    private func beginTurn(sessionId: String) -> UUID {
        clearActiveTurn(sessionId)
        clearPlanState(for: sessionId)
        completedTurnSessionIds.remove(sessionId)
        let turnId = UUID()
        activeTurns[sessionId] = ActiveTurn(
            id: turnId,
            generation: clientGeneration,
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
        activeTurns[sessionId] = ActiveTurn(
            id: UUID(),
            generation: clientGeneration,
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
        staleTurnGenerationBySessionId[sessionId] == clientGeneration
    }

    private func clearStaleSuppressionIfPromptEchoCompleted(for sessionId: String) {
        if pendingUserEchoes[sessionId] == nil {
            staleTurnGenerationBySessionId[sessionId] = nil
        }
    }

    private func cancelTurn(sessionId: String, reason: TurnCancelReason) {
        guard activeTurns[sessionId] != nil || pendingPermissionRequests[sessionId] != nil else { return }
        let request = pendingPermissionRequests[sessionId]
        clearActiveTurn(sessionId)
        pendingPermissionRequests[sessionId] = nil
        queues[sessionId] = nil
        updateRunningFlags()
        updatePermissionFlags()
        completedTurnSessionIds.remove(sessionId)
        updateCompletionFlags()

        switch reason {
        case .manual:
            staleTurnGenerationBySessionId[sessionId] = clientGeneration
            runtimeMessage = nil
            appendStatus(title: "Cancelled", text: "Agent turn cancelled.", to: sessionId)
        case .idleTimeout:
            let message = "Agent runtime disconnected: turn idle timeout"
            runtimeMessage = message
            appendError(title: "Turn timed out", text: "Agent turn was idle for \(turnIdleTimeoutMilliseconds) ms and was cancelled.", key: "turn-timeout-\(sessionId)", to: sessionId)
        }

        let client = client
        Task {
            do {
                try await client?.cancel(sessionId: sessionId)
                if let request {
                    try await client?.cancelPermissionRequest(request.requestId)
                }
                if reason == .idleTimeout {
                    await MainActor.run {
                        cleanupUnhealthyRuntime(message: "Agent runtime disconnected: turn idle timeout")
                    }
                }
            } catch {
                await MainActor.run {
                    cleanupUnhealthyRuntime(message: "Agent runtime disconnected: \(userFacingError(error))")
                }
            }
        }
    }

    private func cleanupUnhealthyRuntime(message: String) {
        for sessionId in activeTurns.keys {
            activeTurns[sessionId]?.watchdogTask?.cancel()
        }
        activeTurns.removeAll()
        staleTurnGenerationBySessionId.removeAll()
        pendingPermissionRequests.removeAll()
        completedTurnSessionIds.removeAll()
        updateRunningFlags()
        updatePermissionFlags()
        updateCompletionFlags()
        clientGeneration += 1
        eventTask?.cancel()
        eventTask = nil
        client?.terminate()
        client = nil
        availability = .disconnected(message)
        runtimeMessage = message
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

    private func row(from summary: AcpSessionSummary) -> AgentSessionRow {
        AgentSessionRow(
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
    }

    private func clearPlanState(for sessionId: String) {
        guard var state = transcriptStates[sessionId] else { return }
        state.plan = nil
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
