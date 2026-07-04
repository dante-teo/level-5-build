import Foundation

public enum LocalTranscriptRole: Equatable, Sendable {
    case user
    case status
}

public struct LocalTranscriptItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: LocalTranscriptRole
    public let text: String

    public init(
        id: UUID = UUID(),
        role: LocalTranscriptRole,
        text: String
    ) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct LocalShellModel: Equatable, Sendable {
    public var draft: String
    public private(set) var transcript: [LocalTranscriptItem]

    public init(
        draft: String = "",
        transcript: [LocalTranscriptItem] = []
    ) {
        self.draft = draft
        self.transcript = transcript
    }

    public mutating func startNewChat() {
        draft = ""
        transcript = []
    }

    @discardableResult
    public mutating func sendDraft() -> Bool {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            draft = ""
            return false
        }

        transcript.append(LocalTranscriptItem(role: .user, text: message))
        transcript.append(LocalTranscriptItem(
            role: .status,
            text: "Message captured."
        ))
        draft = ""
        return true
    }

    public mutating func clearTranscript() {
        transcript = []
    }
}
