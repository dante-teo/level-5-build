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

struct AgentTranscriptPlan: Equatable, Sendable {
    var title: String
    var status: String?
    var text: String
}

struct AgentTranscriptTool: Equatable, Sendable {
    var toolCallId: String
    var title: String
    var kind: String?
    var status: String?
    var text: String?
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
    case plan(AgentTranscriptPlan)
    case tool(AgentTranscriptTool)
    case usage(AgentTranscriptUsage)
    case status(AgentTranscriptStatus)
    case error(AgentTranscriptError)
}

struct AgentTranscriptItem: Identifiable, Equatable, Sendable {
    var id: String
    var kind: AgentTranscriptItemKind
}

enum AgentTranscriptEvent: Equatable, Sendable {
    case messageChunk(role: AgentTranscriptRole, messageId: String?, text: String, unsupportedBlockCount: Int = 0)
    case plan(title: String = "Plan", status: String?, text: String)
    case tool(toolCallId: String, title: String?, kind: String?, status: String?, text: String?)
    case usage(AgentTranscriptUsage)
    case status(title: String, text: String, replacementKey: String? = nil)
    case error(title: String, text: String, replacementKey: String? = nil)
    case stopReason(String)
}

struct AgentTranscriptState: Equatable, Sendable {
    var items: [AgentTranscriptItem] = []
    var latestUsage: AgentTranscriptUsage?
    var stopReasons: [String] = []
    var latestError: String?

    private var nextLocalMessageId = 0

    var renderableItems: [AgentTranscriptItem] { items }

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
        case let .plan(title, status, text):
            upsert(
                AgentTranscriptItem(id: "plan", kind: .plan(.init(title: title, status: status, text: text))),
                into: &state
            )
        case let .tool(toolCallId, title, kind, status, text):
            upsertTool(toolCallId: toolCallId, title: title, kind: kind, status: status, text: text, into: &state)
        case let .usage(usage):
            state.latestUsage = usage
            upsert(AgentTranscriptItem(id: "usage", kind: .usage(usage)), into: &state)
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
            tool.status = status ?? tool.status
            tool.text = text?.nonEmpty ?? tool.text
            state.items[index].kind = .tool(tool)
            return
        }
        let tool = AgentTranscriptTool(
            toolCallId: toolCallId,
            title: title?.nonEmpty ?? "Tool call",
            kind: kind,
            status: status,
            text: text?.nonEmpty
        )
        state.items.append(.init(id: id, kind: .tool(tool)))
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
            return [.tool(
                toolCallId: toolCallId,
                title: object["title"]?.stringValue,
                kind: object["kind"]?.stringValue,
                status: object["status"]?.stringValue,
                text: contentText(from: object["content"])
            )]
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
        let active = entries.first { $0["status"]?.stringValue == "in_progress" }
        let completed = entries.filter { $0["status"]?.stringValue == "completed" }.count
        let total = entries.count
        let text = active?["content"]?.stringValue
            ?? entries.first?["content"]?.stringValue
            ?? "Plan updated."
        let status = active?["status"]?.stringValue
            ?? (total > 0 && completed == total ? "completed" : nil)
        return .plan(status: status, text: total > 0 ? "\(text) (\(completed)/\(total) complete)" : text)
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
