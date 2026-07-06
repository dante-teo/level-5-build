import Foundation
import Level5Core

enum AgentTranscriptRole: Equatable, Sendable {
    case user
    case agent
}

struct AgentTranscriptMessage: Equatable, Sendable {
    var role: AgentTranscriptRole
    var messageId: String?
    var text: String
    var unsupportedBlockCount: Int = 0
}

struct AgentPlanEntry: Identifiable, Equatable, Sendable {
    var id: String
    var content: String
    var status: String
    var priority: String?
}

struct AgentPlanState: Equatable, Sendable {
    var title: String = "Plan"
    var entries: [AgentPlanEntry] = []

    var completedCount: Int {
        entries.filter { AgentTranscriptStatusNormalizer.normalized($0.status) == "completed" }.count
    }

    var totalCount: Int { entries.count }

    var isComplete: Bool {
        !entries.isEmpty && completedCount == totalCount
    }

    var isActive: Bool {
        entries.contains { ["pending", "in_progress"].contains(AgentTranscriptStatusNormalizer.normalized($0.status)) }
    }
}

struct AgentTranscriptTool: Equatable, Sendable {
    var toolCallId: String
    var title: String
    var kind: String?
    var status: String?
    var text: String?
    var isExpanded: Bool = false
}

struct AgentTranscriptUsage: Equatable, Sendable {
    var used: Int?
    var size: Int?
    var amount: Double?
    var currency: String?

    var text: String {
        let context: String? = {
            guard let used else { return nil }
            if let size, size > 0 {
                let percent = Double(used) / Double(size)
                return "\(used.formatted()) / \(size.formatted()) tokens (\(percent.formatted(.percent.precision(.fractionLength(0)))) used)"
            }
            return "\(used.formatted()) tokens used"
        }()
        let cost: String? = {
            guard let amount else { return nil }
            if let currency {
                return "\(currency) \(amount.formatted(.number.precision(.fractionLength(3))))"
            }
            return amount.formatted(.number.precision(.fractionLength(3)))
        }()
        return [context, cost].compactMap(\.self).joined(separator: " - ")
    }
}

struct AgentTranscriptStatus: Equatable, Sendable {
    var title: String
    var text: String
}

struct AgentTranscriptError: Equatable, Sendable {
    var title: String
    var text: String
}

enum AgentTranscriptItemKind: Equatable, Sendable {
    case message(AgentTranscriptMessage)
    case tool(AgentTranscriptTool)
    case status(AgentTranscriptStatus)
    case error(AgentTranscriptError)
}

struct AgentTranscriptItem: Identifiable, Equatable, Sendable {
    var id: String
    var kind: AgentTranscriptItemKind
}

enum AgentTranscriptEvent: Equatable, Sendable {
    case messageChunk(role: AgentTranscriptRole, messageId: String?, text: String, unsupportedBlockCount: Int = 0)
    case plan(title: String = "Plan", entries: [AgentPlanEntry])
    case tool(toolCallId: String, title: String?, kind: String?, status: String?, text: String?)
    case references([AgentReference])
    case toolExpansion(toolCallId: String, isExpanded: Bool)
    case usage(AgentTranscriptUsage)
    case status(title: String, text: String, replacementKey: String? = nil)
    case error(title: String, text: String, replacementKey: String? = nil)
    case stopReason(String)
}

struct AgentTranscriptState: Equatable, Sendable {
    var items: [AgentTranscriptItem] = []
    var latestUsage: AgentTranscriptUsage?
    var plan: AgentPlanState?
    var stopReasons: [String] = []
    var latestError: String?
    var references: [AgentReference] = []

    private var nextLocalMessageId = 0
    fileprivate var manualToolExpansion: [String: Bool] = [:]

    /// `.status` rows (runtime diagnostics, stderr, permission notes,
    /// notable stop reasons, ...) are internal bookkeeping, not something a
    /// user sending a chat message wants cluttering their transcript as a
    /// "Status" bubble, so they're recorded in `items` (and persisted, for
    /// anything that inspects raw state) but never rendered.
    var renderableItems: [AgentTranscriptItem] {
        items.filter { item in
            if case .status = item.kind { return false }
            return true
        }
    }

    mutating func apply(_ event: AgentTranscriptEvent) {
        AgentTranscriptReducer.reduce(event, into: &self)
    }

    mutating func apply(_ events: [AgentTranscriptEvent]) {
        for event in events {
            apply(event)
        }
    }

    fileprivate mutating func nextMessageItemID() -> String {
        nextLocalMessageId += 1
        return "message-local-\(nextLocalMessageId)"
    }
}

enum AgentTranscriptReducer {
    static func reduce(_ event: AgentTranscriptEvent, into state: inout AgentTranscriptState) {
        switch event {
        case let .messageChunk(role, messageId, text, unsupportedBlockCount):
            appendMessage(role: role, messageId: messageId, text: text, unsupportedBlockCount: unsupportedBlockCount, to: &state)
        case let .plan(title, entries):
            state.plan = AgentPlanState(title: title, entries: entries)
        case let .tool(toolCallId, title, kind, status, text):
            upsertTool(toolCallId: toolCallId, title: title, kind: kind, status: status, text: text, into: &state)
        case let .references(references):
            appendReferences(references, into: &state)
        case let .toolExpansion(toolCallId, isExpanded):
            state.manualToolExpansion[toolCallId] = isExpanded
            let id = "tool-\(toolCallId)"
            guard let index = state.items.firstIndex(where: { $0.id == id }),
                  case var .tool(tool) = state.items[index].kind else { return }
            if AgentTranscriptStatusNormalizer.normalized(tool.status) != "failed" {
                tool.isExpanded = isExpanded
                state.items[index].kind = .tool(tool)
            }
        case let .usage(usage):
            state.latestUsage = usage
        case let .status(title, text, replacementKey):
            appendOrReplaceStatus(title: title, text: text, key: replacementKey, into: &state)
        case let .error(title, text, replacementKey):
            state.latestError = text
            appendOrReplaceError(title: title, text: text, key: replacementKey, into: &state)
        case let .stopReason(reason):
            state.stopReasons.append(reason)
            guard isNotableStopReason(reason) else { return }
            appendOrReplaceStatus(
                title: "Stopped",
                text: "Agent turn ended: \(reason).",
                key: "stop-\(reason)",
                into: &state
            )
        }
    }

    private static func appendMessage(
        role: AgentTranscriptRole,
        messageId: String?,
        text: String,
        unsupportedBlockCount: Int,
        to state: inout AgentTranscriptState
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || unsupportedBlockCount > 0 else { return }

        if let messageId,
           let index = state.items.firstIndex(where: { item in
               guard case let .message(message) = item.kind else { return false }
               return message.messageId == messageId && message.role == role
           }) {
            guard case var .message(message) = state.items[index].kind else { return }
            message.text += text
            message.unsupportedBlockCount += unsupportedBlockCount
            state.items[index].kind = .message(message)
            return
        }

        if messageId == nil,
           let last = state.items.last,
           case var .message(message) = last.kind,
           message.role == role,
           message.messageId == nil {
            message.text += text
            message.unsupportedBlockCount += unsupportedBlockCount
            state.items[state.items.count - 1].kind = .message(message)
            return
        }

        let itemID = messageId.map { "message-\($0)" } ?? state.nextMessageItemID()
        let message = AgentTranscriptMessage(
            role: role,
            messageId: messageId,
            text: trimmed,
            unsupportedBlockCount: unsupportedBlockCount
        )
        state.items.append(.init(id: itemID, kind: .message(message)))
    }

    private static func upsertTool(
        toolCallId: String,
        title: String?,
        kind: String?,
        status: String?,
        text: String?,
        into state: inout AgentTranscriptState
    ) {
        let id = "tool-\(toolCallId)"
        if let index = state.items.firstIndex(where: { $0.id == id }),
           case var .tool(tool) = state.items[index].kind {
            tool.title = title?.nonEmpty ?? tool.title
            tool.kind = kind ?? tool.kind
            tool.status = status.map(AgentTranscriptStatusNormalizer.normalized) ?? tool.status
            tool.text = text?.nonEmpty ?? tool.text
            tool.isExpanded = expansionState(
                toolCallId: toolCallId,
                status: tool.status,
                manualToolExpansion: state.manualToolExpansion
            )
            state.items[index].kind = .tool(tool)
            return
        }
        let normalizedStatus = status.map(AgentTranscriptStatusNormalizer.normalized)
        let tool = AgentTranscriptTool(
            toolCallId: toolCallId,
            title: title?.nonEmpty ?? "Tool call",
            kind: kind,
            status: normalizedStatus,
            text: text?.nonEmpty,
            isExpanded: expansionState(
                toolCallId: toolCallId,
                status: normalizedStatus,
                manualToolExpansion: state.manualToolExpansion
            )
        )
        state.items.append(.init(id: id, kind: .tool(tool)))
    }

    private static func appendReferences(_ references: [AgentReference], into state: inout AgentTranscriptState) {
        for reference in references where state.references.contains(where: { $0.hasSameIdentity(as: reference) }) == false {
            state.references.append(reference)
        }
    }

    private static func expansionState(
        toolCallId: String,
        status: String?,
        manualToolExpansion: [String: Bool]
    ) -> Bool {
        let normalizedStatus = AgentTranscriptStatusNormalizer.normalized(status)
        if normalizedStatus == "failed" { return true }
        if let manual = manualToolExpansion[toolCallId] { return manual }
        return normalizedStatus == "in_progress"
    }

    private static func appendOrReplaceStatus(title: String, text: String, key: String?, into state: inout AgentTranscriptState) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = key.map { "status-\($0)" } ?? "status-\(UUID().uuidString)"
        upsert(.init(id: id, kind: .status(.init(title: title, text: trimmed))), into: &state)
    }

    private static func appendOrReplaceError(title: String, text: String, key: String?, into state: inout AgentTranscriptState) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = key.map { "error-\($0)" } ?? "error-\(UUID().uuidString)"
        upsert(.init(id: id, kind: .error(.init(title: title, text: trimmed))), into: &state)
    }

    private static func upsert(_ item: AgentTranscriptItem, into state: inout AgentTranscriptState) {
        if let index = state.items.firstIndex(where: { $0.id == item.id }) {
            state.items[index] = item
        } else {
            state.items.append(item)
        }
    }

    private static func isNotableStopReason(_ reason: String) -> Bool {
        ["cancelled", "refusal", "max_tokens"].contains(reason)
    }

}

enum AgentTranscriptStatusNormalizer {
    static func normalized(_ status: String?) -> String {
        guard let status, !status.isEmpty else { return "" }
        let raw = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        switch raw {
        case "pending", "queued":
            return "pending"
        case "in_progress", "running", "started":
            return "in_progress"
        case "completed", "complete", "succeeded", "success", "done":
            return "completed"
        case "failed", "failure", "error":
            return "failed"
        case "cancelled", "canceled":
            return "cancelled"
        default:
            return raw
        }
    }

    static func display(_ status: String?) -> String? {
        let normalized = normalized(status)
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "pending": return "Pending"
        case "in_progress": return "In Progress"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        default:
            return normalized
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

enum AgentTranscriptNormalizer {
    static func events(from update: AcpSessionUpdate) -> [AgentTranscriptEvent] {
        guard let object = update.update.objectValue else { return [] }
        switch object["sessionUpdate"]?.stringValue {
        case "user_message_chunk":
            return messageEvents(role: .user, object: object)
        case "agent_message_chunk":
            return messageEvents(role: .agent, object: object)
        case "plan":
            return [planEvent(from: object)]
        case "tool_call", "tool_call_update":
            guard let toolCallId = object["toolCallId"]?.stringValue else { return [] }
            var events: [AgentTranscriptEvent] = [.tool(
                toolCallId: toolCallId,
                title: object["title"]?.stringValue,
                kind: object["kind"]?.stringValue,
                status: object["status"]?.stringValue,
                text: contentText(from: object["content"])
            )]
            let references = references(from: object)
            if !references.isEmpty {
                events.append(.references(references))
            }
            return events
        case "usage_update":
            return [.usage(.init(
                used: object["used"]?.intValue,
                size: object["size"]?.intValue,
                amount: object["cost"]?.objectValue?["amount"]?.doubleValue,
                currency: object["cost"]?.objectValue?["currency"]?.stringValue
            ))]
        default:
            return []
        }
    }

    private static func messageEvents(role: AgentTranscriptRole, object: [String: JSONValue]) -> [AgentTranscriptEvent] {
        let content = normalizedContent(from: object["content"])
        guard !content.text.isEmpty || content.unsupportedBlockCount > 0 else { return [] }
        return [.messageChunk(
            role: role,
            messageId: object["messageId"]?.stringValue,
            text: content.text,
            unsupportedBlockCount: content.unsupportedBlockCount
        )]
    }

    private static func planEvent(from object: [String: JSONValue]) -> AgentTranscriptEvent {
        let entries = object["entries"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let planEntries = entries.enumerated().compactMap { index, entry -> AgentPlanEntry? in
            guard let content = entry["content"]?.stringValue?.nonEmpty else { return nil }
            return AgentPlanEntry(
                id: entry["id"]?.stringValue ?? "plan-entry-\(index)",
                content: content,
                status: AgentTranscriptStatusNormalizer.normalized(entry["status"]?.stringValue?.nonEmpty ?? "pending"),
                priority: entry["priority"]?.stringValue
            )
        }
        return .plan(entries: planEntries)
    }

    private static func contentText(from value: JSONValue?) -> String? {
        let content = normalizedContent(from: value)
        var parts: [String] = []
        if !content.text.isEmpty {
            parts.append(content.text)
        }
        if content.unsupportedBlockCount > 0 {
            parts.append(content.unsupportedBlockCount == 1 ? "1 unsupported block" : "\(content.unsupportedBlockCount) unsupported blocks")
        }
        return parts.joined(separator: " - ").nonEmpty
    }

    private static func normalizedContent(from value: JSONValue?) -> (text: String, unsupportedBlockCount: Int) {
        guard let value else { return ("", 0) }
        if let object = value.objectValue {
            return normalizedBlock(from: object)
        }
        if let array = value.arrayValue {
            return array.reduce(into: ("", 0)) { result, value in
                guard let object = value.objectValue else {
                    result.1 += 1
                    return
                }
                let block = normalizedBlock(from: object)
                result.0 += block.text
                result.1 += block.unsupportedBlockCount
            }
        }
        return ("", 1)
    }

    private static func normalizedBlock(from object: [String: JSONValue]) -> (text: String, unsupportedBlockCount: Int) {
        if object["type"]?.stringValue == "text" {
            return (object["text"]?.stringValue ?? "", 0)
        }
        if object["type"]?.stringValue == "content", let nested = object["content"]?.objectValue {
            return normalizedBlock(from: nested)
        }
        return ("", 1)
    }

    private static func references(from object: [String: JSONValue]) -> [AgentReference] {
        var references: [AgentReference] = []
        appendReferences(from: object["content"], into: &references)
        appendLocations(from: object["locations"], into: &references)
        appendReferenceMetadata(from: object["_meta"], into: &references)
        appendReferenceMetadata(from: object["metadata"], into: &references)
        return references
    }

    private static func appendReferences(from value: JSONValue?, into references: inout [AgentReference]) {
        guard let value else { return }
        if let array = value.arrayValue {
            for item in array {
                appendReferences(from: item, into: &references)
            }
            return
        }
        guard let object = value.objectValue else { return }
        if object["type"]?.stringValue == "content" {
            appendReferences(from: object["content"], into: &references)
            return
        }
        if object["type"]?.stringValue == "resource_link",
           let uri = object["uri"]?.stringValue {
            appendReference(
                uri: uri,
                title: object["title"]?.stringValue ?? object["name"]?.stringValue,
                into: &references
            )
            return
        }
        if object["type"]?.stringValue == "resource",
           let resource = object["resource"]?.objectValue,
           let uri = resource["uri"]?.stringValue {
            appendReference(
                uri: uri,
                title: resource["title"]?.stringValue ?? resource["name"]?.stringValue,
                into: &references
            )
        }
    }

    private static func appendLocations(from value: JSONValue?, into references: inout [AgentReference]) {
        guard let locations = value?.arrayValue else { return }
        for location in locations.compactMap(\.objectValue) {
            if let url = location["url"]?.stringValue {
                appendReference(uri: url, title: location["title"]?.stringValue, into: &references)
            }
            if let path = location["path"]?.stringValue {
                appendReference(uri: URL(fileURLWithPath: path).absoluteString, title: location["title"]?.stringValue, into: &references)
            }
            if let uri = location["uri"]?.stringValue {
                appendReference(uri: uri, title: location["title"]?.stringValue, into: &references)
            }
        }
    }

    private static func appendReferenceMetadata(from value: JSONValue?, into references: inout [AgentReference]) {
        guard let object = value?.objectValue else { return }
        if let sources = object["sources"]?.arrayValue ?? object["references"]?.arrayValue {
            for source in sources.compactMap(\.objectValue) {
                let uri = source["url"]?.stringValue ?? source["uri"]?.stringValue
                if let uri {
                    appendReference(uri: uri, title: source["title"]?.stringValue ?? source["name"]?.stringValue, into: &references)
                }
            }
        }
        if let url = object["url"]?.stringValue {
            appendReference(uri: url, title: object["title"]?.stringValue, into: &references)
        }
        if let uri = object["uri"]?.stringValue {
            appendReference(uri: uri, title: object["title"]?.stringValue, into: &references)
        }
    }

    private static func appendReference(uri: String, title: String?, into references: inout [AgentReference]) {
        guard let kind = referenceKind(for: uri) else { return }
        let fallbackTitle = referenceTitle(uri: uri)
        let reference = AgentReference(
            kind: kind,
            title: title?.nonEmpty ?? fallbackTitle,
            uri: uri
        )
        guard references.contains(where: { $0.hasSameIdentity(as: reference) }) == false else { return }
        references.append(reference)
    }

    private static func referenceKind(for uri: String) -> AgentReference.Kind? {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return .web
        }
        if uri.hasPrefix("file://") || uri.hasPrefix("/") {
            return .file
        }
        return nil
    }

    private static func referenceTitle(uri: String) -> String {
        guard let url = URL(string: uri) else { return uri }
        if url.isFileURL {
            return url.lastPathComponent.nonEmpty ?? url.path
        }
        return url.host ?? uri
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    var doubleValue: Double? {
        if case let .number(value) = self { value } else { nil }
    }

    var intValue: Int? {
        guard let doubleValue else { return nil }
        return Int(doubleValue)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
