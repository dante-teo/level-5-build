import Foundation
import Level5Core
import Testing
@testable import Level5BuildApp

@Suite("Composer draft")
struct ComposerDraftTests {
    @Test("Command tokens serialize inline in order")
    func commandsSerializeInline() {
        var draft = ComposerDraft()
        draft.appendText("Use")
        draft.insertCommand(.init(name: "plan"))
        draft.appendText("then")
        draft.insertCommand(.init(name: "review"))
        draft.appendText("the change")

        #expect(draft.serializedText == "Use /plan then /review the change")
    }

    @Test("Command tokens are removed atomically")
    func commandRemovalIsAtomic() throws {
        var draft = ComposerDraft()
        let command = ComposerCommand(id: UUID(), name: "fix")
        draft.appendText("before")
        draft.insertCommand(command)
        draft.appendText("after")

        draft.removePart(id: command.id)

        #expect(draft.parts.count == 2)
        #expect(draft.serializedText == "before after")
    }

    @Test("Text reconciliation preserves accepted command tokens")
    func reconciliationPreservesCommandTokens() throws {
        var draft = ComposerDraft()
        let command = ComposerCommand(id: UUID(), name: "plan")
        draft.appendText("before ")
        draft.insertCommand(command)
        draft.appendText(" after")

        draft.replacePlainTextPreservingCommandTokens("before /plan after please")

        #expect(draft.parts.contains { part in
            if case .command(command) = part { return command.name == "plan" }
            return false
        })
        #expect(draft.serializedText == "before /plan after please")
    }

    @Test("Prompt validation allows attachment-only prompts")
    func promptValidation() {
        var draft = ComposerDraft()
        #expect(draft.isEmpty)

        draft.addAttachments(urls: [URL(fileURLWithPath: "/tmp/a.txt")], kind: .file)
        #expect(draft.isEmpty == false)
    }

    @Test("Attachments normalize, dedupe, and cap at ten")
    func attachmentsNormalizeDedupeAndCap() {
        var draft = ComposerDraft()
        let urls = (0..<12).map { URL(fileURLWithPath: "/tmp/project/../file\($0).txt") }
        draft.addAttachments(urls: urls + [URL(fileURLWithPath: "/tmp/file0.txt")], kind: .file)

        #expect(draft.attachments.count == 10)
        #expect(draft.attachments.first?.url.path == "/tmp/file0.txt")
    }

    @Test("Duplicate basename chips include parent suffix")
    func duplicateBasenameChipsIncludeParent() {
        var draft = ComposerDraft()
        draft.addAttachments(urls: [
            URL(fileURLWithPath: "/tmp/one/README.md"),
            URL(fileURLWithPath: "/tmp/two/README.md")
        ], kind: .file)

        #expect(draft.attachmentChips().map(\.label) == ["README.md - one", "README.md - two"])
    }

    @Test("Prompt blocks contain text then resource links")
    func promptBlocks() {
        var draft = ComposerDraft()
        draft.appendText("Read this")
        draft.addAttachments(urls: [URL(fileURLWithPath: "/tmp/a.txt")], kind: .file)

        #expect(draft.promptBlocks == [
            [
                "type": "text",
                "text": "Read this"
            ],
            [
                "type": "resource_link",
                "uri": "file:///tmp/a.txt",
                "name": "a.txt"
            ]
        ])
    }
}
