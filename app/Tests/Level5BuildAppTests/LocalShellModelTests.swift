import Testing
@testable import Level5BuildApp

@Suite("Local shell model")
struct LocalShellModelTests {
    @Test("New chat clears local transcript and draft")
    func newChatClearsLocalState() {
        var model = LocalShellModel(
            draft: "unfinished",
            transcript: [
                LocalTranscriptItem(role: .user, text: "Hello")
            ]
        )

        model.startNewChat()

        #expect(model.draft.isEmpty)
        #expect(model.transcript.isEmpty)
    }

    @Test("Send ignores empty drafts")
    func sendIgnoresEmptyDrafts() {
        var model = LocalShellModel(draft: " \n\t ")

        let didSend = model.sendDraft()

        #expect(didSend == false)
        #expect(model.draft.isEmpty)
        #expect(model.transcript.isEmpty)
    }

    @Test("Send appends user and placeholder status items")
    func sendAppendsLocalTranscriptItems() {
        var model = LocalShellModel(draft: "Build the shell")

        let didSend = model.sendDraft()

        #expect(didSend)
        #expect(model.draft.isEmpty)
        #expect(model.transcript.map(\.role) == [.user, .status])
        #expect(model.transcript.first?.text == "Build the shell")
        #expect(model.transcript.last?.text == "Message captured.")
    }

    @Test("Clear transcript resets transcript state")
    func clearTranscriptResetsTranscriptState() {
        var model = LocalShellModel(
            draft: "kept",
            transcript: [
                LocalTranscriptItem(role: .user, text: "One"),
                LocalTranscriptItem(role: .status, text: "Two")
            ]
        )

        model.clearTranscript()

        #expect(model.draft == "kept")
        #expect(model.transcript.isEmpty)
    }
}
