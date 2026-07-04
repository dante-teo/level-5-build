import Level5Core
import SwiftUI
import Testing
@testable import Level5BuildApp

@Suite("App smoke tests")
struct AppSmokeTests {
    @Test("Content view can be constructed")
    @MainActor
    func contentViewConstruction() {
        _ = ContentView(recentProjectStore: nil)
    }

    @Test("Composer constructs with approval selector")
    @MainActor
    func composerApprovalSelectorConstruction() {
        _ = ComposerSmokeHarness(pendingPermissionRequest: nil)
    }

    @Test("Composer constructs with permission takeover")
    @MainActor
    func composerPermissionTakeoverConstruction() {
        _ = ComposerSmokeHarness(pendingPermissionRequest: .init(
            requestId: .int(1),
            sessionId: "s1",
            title: "Applying protected mock edit",
            toolKind: "edit",
            toolStatus: "pending",
            detail: "This is a simulated protected action.",
            rawInput: nil,
            options: [
                .init(optionId: "allow-once", name: "Allow once", kind: "allow_once"),
                .init(optionId: "reject-once", name: "Reject", kind: "reject_once")
            ]
        ))
    }
}

private struct ComposerSmokeHarness: View {
    @State private var draft = ComposerDraft()
    @FocusState private var isFocused: Bool
    let pendingPermissionRequest: PermissionRequest?

    var body: some View {
        ComposerView(
            availability: .available,
            runtimeMessage: nil,
            queuedPrompts: [],
            draft: $draft,
            modelOptions: [.init(id: "mock-pro", label: "Mock Pro")],
            slashCommands: [.init(name: "plan")],
            approvalMode: .ask,
            pendingPermissionRequest: pendingPermissionRequest,
            isActiveSessionRunning: false,
            isModelSaveInFlight: false,
            isNewSession: pendingPermissionRequest == nil,
            selectedProject: nil,
            recentProjects: [],
            canSendWithButton: false,
            canEditComposer: pendingPermissionRequest == nil,
            isFocused: $isFocused,
            sendAction: {},
            selectModelAction: { _ in },
            selectApprovalModeAction: { _ in },
            respondToPermissionAction: { _ in },
            rejectPermissionWithInstructionsAction: { _ in },
            addAttachmentsAction: { _, _ in },
            removeAttachmentAction: { _ in },
            acceptSlashCommandAction: { _ in },
            removeQueuedPromptAction: { _ in },
            selectProjectAction: { _ in },
            clearProjectAction: {},
            removeRecentProjectAction: { _ in },
            validateProjectAction: { _ in true }
        )
    }
}
