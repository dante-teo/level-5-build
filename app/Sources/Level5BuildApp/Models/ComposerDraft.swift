import Foundation
import Level5Core

struct ComposerCommand: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var displayName: String?
    var commandDescription: String?
    var inputHint: String?

    init(
        id: UUID = UUID(),
        name: String,
        displayName: String? = nil,
        commandDescription: String? = nil,
        inputHint: String? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.displayName = displayName
        self.commandDescription = commandDescription
        self.inputHint = inputHint
    }

    var rawText: String {
        "/" + name
    }

    var label: String {
        displayName?.nonEmpty ?? name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var systemImage: String {
        let lowered = name.lowercased()
        if lowered.contains("plan") { return "checklist" }
        if lowered.contains("test") { return "testtube.2" }
        if lowered.contains("fix") { return "wrench.and.screwdriver" }
        if lowered.contains("review") { return "text.magnifyingglass" }
        if lowered.contains("commit") { return "arrow.trianglehead.branch" }
        return "slash.circle"
    }
}

enum ComposerPart: Identifiable, Equatable, Sendable {
    case text(id: UUID, String)
    case command(ComposerCommand)

    var id: UUID {
        switch self {
        case let .text(id, _): id
        case let .command(command): command.id
        }
    }

    var previewText: String {
        switch self {
        case let .text(_, text): text
        case let .command(command): command.rawText
        }
    }
}

struct ComposerAttachment: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case file
        case folder
    }

    var id: UUID
    var url: URL
    var kind: Kind

    init(id: UUID = UUID(), url: URL, kind: Kind) {
        self.id = id
        self.url = url.standardizedFileURL
        self.kind = kind
    }

    var basename: String {
        url.lastPathComponent.nonEmpty ?? url.path
    }

    var parentName: String {
        url.deletingLastPathComponent().lastPathComponent.nonEmpty ?? url.deletingLastPathComponent().path
    }

    var resourceLinkBlock: JSONValue {
        [
            "type": "resource_link",
            "uri": .string(url.absoluteString),
            "name": .string(basename)
        ]
    }
}

struct ComposerAttachmentChip: Identifiable, Equatable, Sendable {
    var id: UUID { attachment.id }
    var attachment: ComposerAttachment
    var label: String
}

struct ComposerModelOption: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var modelDescription: String?

    init(id: String, label: String? = nil, modelDescription: String? = nil) {
        self.id = id
        self.label = label?.nonEmpty ?? Self.readableLabel(from: id)
        self.modelDescription = modelDescription
    }

    private static func readableLabel(from id: String) -> String {
        id
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.uppercased() == String($0) ? String($0) : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

struct ComposerDraft: Equatable, Sendable {
    static let maxAttachments = 10

    var parts: [ComposerPart] = []
    var attachments: [ComposerAttachment] = []
    var selectedModelId: String?

    var plainText: String {
        get { parts.map(\.previewText).joined() }
        set {
            parts = newValue.isEmpty ? [] : [.text(id: UUID(), newValue)]
        }
    }

    var isEmpty: Bool {
        serializedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    var serializedText: String {
        parts.reduce("") { partial, part in
            append(part.previewText, to: partial)
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var promptBlocks: [JSONValue] {
        var blocks: [JSONValue] = []
        let text = serializedText
        if !text.isEmpty {
            blocks.append([
                "type": "text",
                "text": .string(text)
            ])
        }
        blocks.append(contentsOf: attachments.map(\.resourceLinkBlock))
        return blocks
    }

    var previewText: String {
        let text = serializedText
        let attachmentText = attachments.map { $0.basename }.joined(separator: ", ")
        switch (text.isEmpty, attachmentText.isEmpty) {
        case (true, true):
            return ""
        case (false, true):
            return text
        case (true, false):
            return attachmentText
        case (false, false):
            return "\(text)  \(attachmentText)"
        }
    }

    mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if case let .text(id, existing)? = parts.last {
            parts[parts.count - 1] = .text(id: id, existing + text)
        } else {
            parts.append(.text(id: UUID(), text))
        }
    }

    mutating func insertCommand(_ command: ComposerCommand, at index: Int? = nil) {
        let insertionIndex = index.map { max(0, min($0, parts.count)) } ?? parts.count
        parts.insert(.command(command), at: insertionIndex)
    }

    mutating func removePart(id: UUID) {
        parts.removeAll { $0.id == id }
    }

    mutating func addAttachments(urls: [URL], kind: ComposerAttachment.Kind) {
        var seen = Set(attachments.map { $0.url.standardizedFileURL.path })
        for url in urls {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            guard attachments.count < Self.maxAttachments else { break }
            attachments.append(.init(url: standardized, kind: kind))
        }
    }

    mutating func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    mutating func clearAfterSend() {
        parts = []
        attachments = []
    }

    mutating func replacePlainTextPreservingCommandTokens(_ text: String) {
        let commands = parts.compactMap { part -> ComposerCommand? in
            if case let .command(command) = part { return command }
            return nil
        }
        guard !commands.isEmpty else {
            plainText = text
            return
        }

        var rebuilt: [ComposerPart] = []
        var cursor = text.startIndex
        var remaining = text[cursor...]
        for command in commands {
            guard let range = remaining.range(of: command.rawText) else { continue }
            if range.lowerBound > cursor {
                rebuilt.append(.text(id: UUID(), String(text[cursor..<range.lowerBound])))
            }
            rebuilt.append(.command(command))
            cursor = range.upperBound
            remaining = text[cursor...]
        }
        if cursor < text.endIndex {
            rebuilt.append(.text(id: UUID(), String(text[cursor..<text.endIndex])))
        }
        parts = rebuilt.isEmpty && !text.isEmpty ? [.text(id: UUID(), text)] : rebuilt
    }

    func attachmentChips() -> [ComposerAttachmentChip] {
        let basenameCounts = Dictionary(grouping: attachments, by: \.basename).mapValues(\.count)
        return attachments.map { attachment in
            let label = basenameCounts[attachment.basename, default: 0] > 1
                ? "\(attachment.basename) - \(attachment.parentName)"
                : attachment.basename
            return ComposerAttachmentChip(attachment: attachment, label: label)
        }
    }

    private func append(_ next: String, to current: String) -> String {
        guard !next.isEmpty else { return current }
        guard !current.isEmpty else { return next }
        if current.last?.isWhitespace == true || next.first?.isWhitespace == true {
            return current + next
        }
        if current.last?.isNewline == true || next.first?.isNewline == true {
            return current + next
        }
        return current + " " + next
    }
}

extension ComposerDraft: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.init()
        plainText = value
    }
}

func == (left: ComposerDraft, right: String) -> Bool {
    left.plainText == right
}

func == (left: String, right: ComposerDraft) -> Bool {
    left == right.plainText
}

struct QueuedPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let snapshot: ComposerDraft

    init(id: UUID = UUID(), snapshot: ComposerDraft) {
        self.id = id
        self.snapshot = snapshot
    }

    init(id: UUID = UUID(), text: String) {
        var draft = ComposerDraft()
        draft.plainText = text
        self.init(id: id, snapshot: draft)
    }

    var text: String {
        snapshot.previewText
    }

    var promptBlocks: [JSONValue] {
        snapshot.promptBlocks
    }
}

extension ComposerDraft {
    static func text(_ value: String) -> ComposerDraft {
        var draft = ComposerDraft()
        draft.plainText = value
        return draft
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
