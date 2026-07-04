import Foundation
import Level5Core

public enum LocalTranscriptRole: Equatable, Sendable {
    case user
    case agent
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
    public private(set) var selectedProject: RecentProject?

    public init(
        draft: String = "",
        transcript: [LocalTranscriptItem] = [],
        selectedProject: RecentProject? = nil
    ) {
        self.draft = draft
        self.transcript = transcript
        self.selectedProject = selectedProject
    }

    public var isNewSession: Bool {
        transcript.isEmpty
    }

    public var isProjectSelectionAvailable: Bool {
        isNewSession
    }

    public var selectedProjectPath: String? {
        selectedProject?.path
    }

    public mutating func startNewChat() {
        draft = ""
        transcript = []
    }

    public mutating func selectProject(_ project: RecentProject) {
        guard isProjectSelectionAvailable else { return }

        selectedProject = project
    }

    public mutating func clearSelectedProject() {
        guard isProjectSelectionAvailable else { return }

        selectedProject = nil
    }

    @discardableResult
    public mutating func sendDraft() -> Bool {
        guard submitDraft() != nil else { return false }

        return true
    }

    public mutating func submitDraft() -> String? {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            draft = ""
            return nil
        }

        transcript.append(LocalTranscriptItem(role: .user, text: message))
        draft = ""
        return message
    }

    public mutating func appendAgentText(_ text: String) {
        appendText(text, role: .agent)
    }

    public mutating func appendStatus(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        transcript.append(LocalTranscriptItem(role: .status, text: trimmed))
    }

    public mutating func clearTranscript() {
        transcript = []
    }

    private mutating func appendText(_ text: String, role: LocalTranscriptRole) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if transcript.last?.role == role, let last = transcript.popLast() {
            transcript.append(LocalTranscriptItem(
                id: last.id,
                role: role,
                text: last.text + text
            ))
        } else {
            transcript.append(LocalTranscriptItem(role: role, text: trimmed))
        }
    }
}
