import Foundation
import Testing
import Level5Core
@testable import Level5BuildApp

@Suite("Local shell model")
struct LocalShellModelTests {
    @Test("New chat clears local transcript and draft")
    func newChatClearsLocalState() {
        let project = RecentProject(
            path: "/tmp/level-5-build",
            displayName: "level-5-build",
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 0)
        )
        var model = LocalShellModel(
            draft: "unfinished",
            transcript: [
                LocalTranscriptItem(role: .user, text: "Hello")
            ],
            selectedProject: project
        )

        model.startNewChat()

        #expect(model.draft.isEmpty)
        #expect(model.transcript.isEmpty)
        #expect(model.selectedProject == project)
        #expect(model.isProjectSelectionAvailable)
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

    @Test("First send locks selected project context")
    func firstSendLocksSelectedProjectContext() {
        let project = RecentProject(
            path: "/tmp/level-5-build",
            displayName: "level-5-build",
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 0)
        )
        var model = LocalShellModel(draft: "Build the shell", selectedProject: project)

        let didSend = model.sendDraft()

        #expect(didSend)
        #expect(model.selectedProjectPath == "/tmp/level-5-build")
        #expect(model.isProjectSelectionAvailable == false)
    }

    @Test("Folderless send keeps selected project nil")
    func folderlessSendKeepsSelectedProjectNil() {
        var model = LocalShellModel(draft: "Build without a folder")

        let didSend = model.sendDraft()

        #expect(didSend)
        #expect(model.selectedProject == nil)
        #expect(model.selectedProjectPath == nil)
    }

    @Test("Selected project remains window local state")
    func selectedProjectIsNotRestoredByDefault() {
        let selected = RecentProject(
            path: "/tmp/level-5-build",
            displayName: "level-5-build",
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 0)
        )
        let modelWithSelection = LocalShellModel(selectedProject: selected)
        let freshModel = LocalShellModel()

        #expect(modelWithSelection.selectedProjectPath == "/tmp/level-5-build")
        #expect(freshModel.selectedProject == nil)
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
