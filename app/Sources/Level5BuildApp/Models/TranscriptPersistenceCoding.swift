import Foundation
import Level5Core

/// Small `Codable` DTOs mirroring the shapes `AgentTranscriptState` holds in
/// memory, plus pure mapping functions to/from the shape-agnostic
/// `Level5Core.SessionPersistenceStore` payloads. `AgentTranscriptReducer`
/// stays pure/IO-free; all persistence encode/decode lives at this
/// app-private boundary.
private struct PersistedMessagePayload: Codable {
    var role: String
    var messageId: String?
    var text: String
    var unsupportedBlockCount: Int
}

private struct PersistedToolPayload: Codable {
    var toolCallId: String
    var title: String
    var kind: String?
    var status: String?
    var text: String?
}

private struct PersistedStatusPayload: Codable {
    var title: String
    var text: String
}

private struct PersistedErrorPayload: Codable {
    var title: String
    var text: String
}

private struct PersistedPlanEntryPayload: Codable {
    var id: String
    var content: String
    var status: String
    var priority: String?
}

private struct PersistedPlanPayload: Codable {
    var title: String
    var entries: [PersistedPlanEntryPayload]
}

private struct PersistedUsagePayload: Codable {
    var used: Int?
    var size: Int?
    var amount: Double?
    var currency: String?
}

private struct PersistedReferencePayload: Codable {
    var kind: String
    var title: String
    var uri: String
}

enum TranscriptPersistenceCoding {
    /// Bumped whenever a persisted payload's shape changes incompatibly. A
    /// version mismatch on read is treated as a cache miss, not an error:
    /// this is a cache, not the source of truth.
    static let payloadVersion = 1

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Transcript items

    static func encode(_ item: AgentTranscriptItem) -> PersistedTranscriptItem? {
        switch item.kind {
        case let .message(message):
            return encodePayload(PersistedMessagePayload(
                role: message.role == .user ? "user" : "agent",
                messageId: message.messageId,
                text: message.text,
                unsupportedBlockCount: message.unsupportedBlockCount
            ), itemId: item.id, kind: "message")
        case let .tool(tool):
            return encodePayload(PersistedToolPayload(
                toolCallId: tool.toolCallId,
                title: tool.title,
                kind: tool.kind,
                status: tool.status,
                text: tool.text
            ), itemId: item.id, kind: "tool")
        case let .status(status):
            return encodePayload(PersistedStatusPayload(title: status.title, text: status.text), itemId: item.id, kind: "status")
        case let .error(error):
            return encodePayload(PersistedErrorPayload(title: error.title, text: error.text), itemId: item.id, kind: "error")
        }
    }

    static func decode(_ persisted: PersistedTranscriptItem) -> AgentTranscriptItem? {
        guard persisted.payloadVersion == payloadVersion else { return nil }
        switch persisted.kind {
        case "message":
            guard let payload = try? decoder.decode(PersistedMessagePayload.self, from: persisted.payload) else { return nil }
            return AgentTranscriptItem(id: persisted.itemId, kind: .message(.init(
                role: payload.role == "user" ? .user : .agent,
                messageId: payload.messageId,
                text: payload.text,
                unsupportedBlockCount: payload.unsupportedBlockCount
            )))
        case "tool":
            guard let payload = try? decoder.decode(PersistedToolPayload.self, from: persisted.payload) else { return nil }
            // Manual expand/collapse overrides are not persisted: re-derive
            // the default expand-while-running/collapse-when-done heuristic
            // from the cached status rather than trusting a stored flag.
            let normalizedStatus = AgentTranscriptStatusNormalizer.normalized(payload.status)
            let isExpanded = normalizedStatus == "failed" || normalizedStatus == "in_progress"
            return AgentTranscriptItem(id: persisted.itemId, kind: .tool(.init(
                toolCallId: payload.toolCallId,
                title: payload.title,
                kind: payload.kind,
                status: payload.status,
                text: payload.text,
                isExpanded: isExpanded
            )))
        case "status":
            guard let payload = try? decoder.decode(PersistedStatusPayload.self, from: persisted.payload) else { return nil }
            return AgentTranscriptItem(id: persisted.itemId, kind: .status(.init(title: payload.title, text: payload.text)))
        case "error":
            guard let payload = try? decoder.decode(PersistedErrorPayload.self, from: persisted.payload) else { return nil }
            return AgentTranscriptItem(id: persisted.itemId, kind: .error(.init(title: payload.title, text: payload.text)))
        default:
            return nil
        }
    }

    // MARK: - Singleton transcript state (plan/usage/stopReasons/references)

    static func encodeState(_ state: AgentTranscriptState) -> PersistedTranscriptState {
        PersistedTranscriptState(
            planPayload: state.plan.flatMap { plan in
                try? encoder.encode(PersistedPlanPayload(
                    title: plan.title,
                    entries: plan.entries.map { .init(id: $0.id, content: $0.content, status: $0.status, priority: $0.priority) }
                ))
            },
            usagePayload: state.latestUsage.flatMap { usage in
                try? encoder.encode(PersistedUsagePayload(used: usage.used, size: usage.size, amount: usage.amount, currency: usage.currency))
            },
            stopReasonsPayload: try? encoder.encode(state.stopReasons),
            referencesPayload: try? encoder.encode(state.references.map {
                PersistedReferencePayload(kind: $0.kind == .web ? "web" : "file", title: $0.title, uri: $0.uri)
            }),
            payloadVersion: payloadVersion
        )
    }

    /// Applies a persisted singleton row onto `state`. Each field is decoded
    /// independently; a version mismatch or decode failure on any one field
    /// is a cache miss for that field only, not for the whole row.
    static func apply(_ persisted: PersistedTranscriptState, to state: inout AgentTranscriptState) {
        guard persisted.payloadVersion == payloadVersion else { return }
        if let planPayload = persisted.planPayload,
           let plan = try? decoder.decode(PersistedPlanPayload.self, from: planPayload) {
            state.plan = AgentPlanState(
                title: plan.title,
                entries: plan.entries.map { .init(id: $0.id, content: $0.content, status: $0.status, priority: $0.priority) }
            )
        }
        if let usagePayload = persisted.usagePayload,
           let usage = try? decoder.decode(PersistedUsagePayload.self, from: usagePayload) {
            state.latestUsage = AgentTranscriptUsage(used: usage.used, size: usage.size, amount: usage.amount, currency: usage.currency)
        }
        if let stopReasonsPayload = persisted.stopReasonsPayload,
           let stopReasons = try? decoder.decode([String].self, from: stopReasonsPayload) {
            state.stopReasons = stopReasons
        }
        if let referencesPayload = persisted.referencesPayload,
           let references = try? decoder.decode([PersistedReferencePayload].self, from: referencesPayload) {
            state.references = references.map { AgentReference(kind: $0.kind == "web" ? .web : .file, title: $0.title, uri: $0.uri) }
        }
    }

    private static func encodePayload(_ payload: some Encodable, itemId: String, kind: String) -> PersistedTranscriptItem? {
        guard let data = try? encoder.encode(payload) else { return nil }
        return PersistedTranscriptItem(itemId: itemId, kind: kind, payloadVersion: payloadVersion, payload: data)
    }
}
