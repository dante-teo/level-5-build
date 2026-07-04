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

    @Test("Composer constructs with plan and usage metadata")
    @MainActor
    func composerPlanAndUsageConstruction() {
        _ = ComposerSmokeHarness(
            plan: .init(entries: [
                .init(id: "1", content: "Inspect state", status: "completed", priority: "high"),
                .init(id: "2", content: "Render progress", status: "in_progress", priority: "high")
            ]),
            usage: .init(used: 72_000, size: 100_000, amount: 0.012, currency: "USD")
        )
    }
}

private struct ComposerSmokeHarness: View {
    @State private var draft = ComposerDraft()
    @FocusState private var isFocused: Bool
    var plan: AgentPlanState?
    var usage: AgentTranscriptUsage?
    let pendingPermissionRequest: PermissionRequest?

    init(
        plan: AgentPlanState? = nil,
        usage: AgentTranscriptUsage? = nil,
        pendingPermissionRequest: PermissionRequest? = nil
    ) {
        self.plan = plan
        self.usage = usage
        self.pendingPermissionRequest = pendingPermissionRequest
    }

    var body: some View {
        ComposerView(
            availability: .available,
            runtimeMessage: nil,
            queuedPrompts: [],
            plan: plan,
            usage: usage,
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
            cancelAction: {},
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
