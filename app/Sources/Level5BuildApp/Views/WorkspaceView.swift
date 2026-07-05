import Level5Core
import Level5Design
import SwiftUI

struct WorkspaceView: View {
    let transcript: [AgentTranscriptItem]
    let activeSessionId: String?
    let transcriptFollowsTail: Bool
    let availability: AgentAvailability
    let runtimeMessage: String?
    let queuedPrompts: [QueuedPrompt]
    let plan: AgentPlanState?
    let usage: AgentTranscriptUsage?
    let dashboard: ProjectDashboardState?
    @Binding var draft: ComposerDraft
    let modelOptions: [ComposerModelOption]
    let slashCommands: [ComposerCommand]
    let approvalMode: ApprovalMode
    let pendingPermissionRequest: PermissionRequest?
    let isActiveSessionRunning: Bool
    let isModelSaveInFlight: Bool
    let selectedProject: RecentProject?
    let recentProjects: [RecentProject]
    let canSendWithButton: Bool
    let canEditComposer: Bool
    var isComposerFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void
    let cancelAction: () -> Void
    let selectModelAction: (String) -> Void
    let selectApprovalModeAction: (ApprovalMode) -> Void
    let respondToPermissionAction: (String) -> Void
    let rejectPermissionWithInstructionsAction: (String) -> Void
    let addAttachmentsAction: ([URL], ComposerAttachment.Kind) -> Void
    let removeAttachmentAction: (ComposerAttachment) -> Void
    let acceptSlashCommandAction: (ComposerCommand) -> Void
    let setTranscriptFollowsTailAction: (Bool) -> Void
    let refreshDashboardAction: () -> Void
    let removeQueuedPromptAction: (QueuedPrompt) -> Void
    let selectProjectAction: (URL) -> Void
    let clearProjectAction: () -> Void
    let removeRecentProjectAction: (RecentProject) -> Void
    let validateProjectAction: (RecentProject) -> Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var adaptiveDashboard = ProjectDashboardAdaptiveState()
    @State private var topBarHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if transcript.isEmpty {
                    NewSessionView(
                        availability: availability,
                        runtimeMessage: runtimeMessage,
                        queuedPrompts: queuedPrompts,
                        plan: plan,
                        usage: usage,
                        draft: $draft,
                        modelOptions: modelOptions,
                        slashCommands: slashCommands,
                        approvalMode: approvalMode,
                        pendingPermissionRequest: pendingPermissionRequest,
                        isActiveSessionRunning: isActiveSessionRunning,
                        isModelSaveInFlight: isModelSaveInFlight,
                        selectedProject: selectedProject,
                        recentProjects: recentProjects,
                        canSendWithButton: canSendWithButton,
                        canEditComposer: canEditComposer,
                        isComposerFocused: isComposerFocused,
                        sendAction: sendAction,
                        cancelAction: cancelAction,
                        selectModelAction: selectModelAction,
                        selectApprovalModeAction: selectApprovalModeAction,
                        respondToPermissionAction: respondToPermissionAction,
                        rejectPermissionWithInstructionsAction: rejectPermissionWithInstructionsAction,
                        addAttachmentsAction: addAttachmentsAction,
                        removeAttachmentAction: removeAttachmentAction,
                        acceptSlashCommandAction: acceptSlashCommandAction,
                        removeQueuedPromptAction: removeQueuedPromptAction,
                        selectProjectAction: selectProjectAction,
                        clearProjectAction: clearProjectAction,
                        removeRecentProjectAction: removeRecentProjectAction,
                        validateProjectAction: validateProjectAction
                    )
                } else {
                    sessionWorkspace(size: geometry.size)
                }

                WorkspaceTopBar(
                    title: topBarTitle,
                    subtitle: topBarSubtitle,
                    hasDashboard: dashboard != nil,
                    isDashboardVisible: dashboard != nil && adaptiveDashboard.presentation != .hidden,
                    toggleDashboardAction: {
                        adaptiveDashboard.toggle()
                        if adaptiveDashboard.presentation != .hidden {
                            refreshDashboardAction()
                        }
                    }
                )
                .measureWorkspaceTopBarHeight()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .onPreferenceChange(WorkspaceTopBarHeightPreferenceKey.self) { height in
                guard height > .zero else { return }
                topBarHeight = height
            }
        }
        .background(L5Color.background)
        .onChange(of: activeSessionId) { _, _ in
            adaptiveDashboard.resetForContextChange()
        }
        .onChange(of: dashboard?.projectPath) { _, _ in
            adaptiveDashboard.resetForContextChange()
        }
    }

    private var topBarTitle: String {
        selectedProject?.displayName ?? "Level5 Build"
    }

    private var topBarSubtitle: String {
        if isActiveSessionRunning {
            return "Running"
        }
        if let dashboard {
            if dashboard.gitStatus.isAvailable {
                return dashboard.gitStatus.branch ?? "Project session"
            }
            return "Project session"
        }
        return activeSessionId == nil ? "New chat" : "Chat"
    }

    @ViewBuilder
    private func sessionWorkspace(size: CGSize) -> some View {
        let presentation = dashboard == nil ? ProjectDashboardPresentation.hidden : adaptiveDashboard.presentation

        ZStack(alignment: .trailing) {
            transcriptAndComposer
                .padding(.trailing, presentation == .reserved ? L5WorkspaceDashboardLayout.reservedContentInset(for: size.width) : .zero)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if presentation == .reserved, let dashboard {
                ProjectDashboardView(
                    state: dashboard,
                    plan: plan,
                    refreshAction: refreshDashboardAction,
                    closeAction: { adaptiveDashboard.close() }
                )
                .frame(width: L5WorkspaceDashboardLayout.reservedWidth(for: size.width))
                .frame(maxHeight: L5WorkspaceDashboardLayout.reservedMaxHeight(for: size.height), alignment: .top)
                .padding(.trailing, L5Spacing.x5)
                .padding(.top, L5WorkspaceTopBar.floatingSurfaceTopInset(for: topBarHeight))
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .onAppear(perform: refreshDashboardAction)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if presentation == .overlay, let dashboard {
                ProjectDashboardView(
                    state: dashboard,
                    plan: plan,
                    refreshAction: refreshDashboardAction,
                    closeAction: { adaptiveDashboard.close() }
                )
                .frame(width: L5WorkspaceDashboardLayout.overlayWidth(for: size.width))
                .frame(maxHeight: L5WorkspaceDashboardLayout.popoverMaxHeight(for: size.height), alignment: .top)
                .padding(.top, L5WorkspaceTopBar.floatingSurfaceTopInset(for: topBarHeight))
                .padding(.trailing, L5Spacing.x4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .onAppear {
            adaptiveDashboard.update(horizontalSizeClass: horizontalSizeClass, workspaceWidth: size.width)
        }
        .onChange(of: size.width) { _, newWidth in
            adaptiveDashboard.update(horizontalSizeClass: horizontalSizeClass, workspaceWidth: newWidth)
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            adaptiveDashboard.update(horizontalSizeClass: sizeClass, workspaceWidth: size.width)
        }
    }

    private var transcriptAndComposer: some View {
        VStack(spacing: L5WorkspaceDashboardLayout.splitSpacing) {
            TranscriptView(
                items: transcript,
                scrollIdentity: activeSessionId,
                topContentInset: L5WorkspaceTopBar.scrollContentTopInset(for: topBarHeight),
                followsTail: transcriptFollowsTail,
                setFollowsTail: setTranscriptFollowsTailAction
            )
            .id(activeSessionId)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .clipped()

            ComposerView(
                availability: availability,
                runtimeMessage: runtimeMessage,
                queuedPrompts: queuedPrompts,
                plan: plan,
                usage: usage,
                draft: $draft,
                modelOptions: modelOptions,
                slashCommands: slashCommands,
                approvalMode: approvalMode,
                pendingPermissionRequest: pendingPermissionRequest,
                isActiveSessionRunning: isActiveSessionRunning,
                isModelSaveInFlight: isModelSaveInFlight,
                isNewSession: false,
                selectedProject: selectedProject,
                recentProjects: recentProjects,
                canSendWithButton: canSendWithButton,
                canEditComposer: canEditComposer,
                isFocused: isComposerFocused,
                sendAction: sendAction,
                cancelAction: cancelAction,
                selectModelAction: selectModelAction,
                selectApprovalModeAction: selectApprovalModeAction,
                respondToPermissionAction: respondToPermissionAction,
                rejectPermissionWithInstructionsAction: rejectPermissionWithInstructionsAction,
                addAttachmentsAction: addAttachmentsAction,
                removeAttachmentAction: removeAttachmentAction,
                acceptSlashCommandAction: acceptSlashCommandAction,
                removeQueuedPromptAction: removeQueuedPromptAction,
                selectProjectAction: selectProjectAction,
                clearProjectAction: clearProjectAction,
                removeRecentProjectAction: removeRecentProjectAction,
                validateProjectAction: validateProjectAction
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, L5Spacing.x6)
            .padding(.bottom, L5Spacing.x5)
        }
    }
}

private struct NewSessionView: View {
    let availability: AgentAvailability
    let runtimeMessage: String?
    let queuedPrompts: [QueuedPrompt]
    let plan: AgentPlanState?
    let usage: AgentTranscriptUsage?
    @Binding var draft: ComposerDraft
    let modelOptions: [ComposerModelOption]
    let slashCommands: [ComposerCommand]
    let approvalMode: ApprovalMode
    let pendingPermissionRequest: PermissionRequest?
    let isActiveSessionRunning: Bool
    let isModelSaveInFlight: Bool
    let selectedProject: RecentProject?
    let recentProjects: [RecentProject]
    let canSendWithButton: Bool
    let canEditComposer: Bool
    var isComposerFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void
    let cancelAction: () -> Void
    let selectModelAction: (String) -> Void
    let selectApprovalModeAction: (ApprovalMode) -> Void
    let respondToPermissionAction: (String) -> Void
    let rejectPermissionWithInstructionsAction: (String) -> Void
    let addAttachmentsAction: ([URL], ComposerAttachment.Kind) -> Void
    let removeAttachmentAction: (ComposerAttachment) -> Void
    let acceptSlashCommandAction: (ComposerCommand) -> Void
    let removeQueuedPromptAction: (QueuedPrompt) -> Void
    let selectProjectAction: (URL) -> Void
    let clearProjectAction: () -> Void
    let removeRecentProjectAction: (RecentProject) -> Void
    let validateProjectAction: (RecentProject) -> Bool

    var body: some View {
        VStack(spacing: L5Spacing.x6) {
            Spacer(minLength: L5Spacing.x16)

            VStack(spacing: L5Spacing.x6) {
                Text(title)
                    .font(L5Font.h2)
                    .foregroundStyle(L5Color.textPrimary)
                    .multilineTextAlignment(.center)

                ComposerView(
                    availability: availability,
                    runtimeMessage: runtimeMessage,
                    queuedPrompts: queuedPrompts,
                    plan: plan,
                    usage: usage,
                    draft: $draft,
                    modelOptions: modelOptions,
                    slashCommands: slashCommands,
                    approvalMode: approvalMode,
                    pendingPermissionRequest: pendingPermissionRequest,
                    isActiveSessionRunning: isActiveSessionRunning,
                    isModelSaveInFlight: isModelSaveInFlight,
                    isNewSession: true,
                    selectedProject: selectedProject,
                    recentProjects: recentProjects,
                    canSendWithButton: canSendWithButton,
                    canEditComposer: canEditComposer,
                    isFocused: isComposerFocused,
                    sendAction: sendAction,
                    cancelAction: cancelAction,
                    selectModelAction: selectModelAction,
                    selectApprovalModeAction: selectApprovalModeAction,
                    respondToPermissionAction: respondToPermissionAction,
                    rejectPermissionWithInstructionsAction: rejectPermissionWithInstructionsAction,
                    addAttachmentsAction: addAttachmentsAction,
                    removeAttachmentAction: removeAttachmentAction,
                    acceptSlashCommandAction: acceptSlashCommandAction,
                    removeQueuedPromptAction: removeQueuedPromptAction,
                    selectProjectAction: selectProjectAction,
                    clearProjectAction: clearProjectAction,
                    removeRecentProjectAction: removeRecentProjectAction,
                    validateProjectAction: validateProjectAction
                )
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: L5Spacing.x16)
        }
        .padding(.horizontal, L5Spacing.x8)
        .padding(.bottom, L5Spacing.x16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if let selectedProject {
            "What should we build in \(selectedProject.displayName)?"
        } else {
            "What should we build?"
        }
    }
}

private struct WorkspaceTopBar: View {
    let title: String
    let subtitle: String
    let hasDashboard: Bool
    let isDashboardVisible: Bool
    let toggleDashboardAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: L5Spacing.x5) {
            VStack(alignment: .leading, spacing: L5Spacing.x1) {
                Text(title)
                    .font(L5Font.body.weight(.semibold))
                    .foregroundStyle(L5Color.textPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(L5Font.caption)
                    .foregroundStyle(L5Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GlassIconButton(
                systemImage: "slider.horizontal.3",
                isSelected: isDashboardVisible,
                isEnabled: hasDashboard,
                help: "Dashboard",
                action: toggleDashboardAction
            )
            .glassCircle()
        }
        .padding(.horizontal, L5Spacing.x5)
        .padding(.leading, L5WorkspaceTopBar.leadingWindowControlsInset)
        .padding(.vertical, L5WorkspaceTopBar.verticalPadding)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            TopBarFade()
                .ignoresSafeArea(.container, edges: .top)
        }
    }
}

private struct TopBarFade: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                stops: [
                    .init(color: L5Color.elevatedSurface.opacity(L5WorkspaceTopBar.fadeTintTopOpacity), location: L5WorkspaceTopBar.fadeStart),
                    .init(color: L5Color.surface.opacity(L5WorkspaceTopBar.fadeTintMidOpacity), location: L5WorkspaceTopBar.fadeMid),
                    .init(color: .clear, location: L5WorkspaceTopBar.fadeEnd)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: L5WorkspaceTopBar.fadeHeight)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: L5WorkspaceTopBar.fadeStart),
                    .init(color: .black.opacity(.zero), location: L5WorkspaceTopBar.fadeEnd)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct GlassIconButton: View {
    let systemImage: String
    var isSelected = false
    var isEnabled = true
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(L5Font.h3)
                .foregroundStyle(isSelected ? L5Color.textPrimary : L5Color.textSecondary)
                .frame(width: L5Size.hitTarget, height: L5Size.hitTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : L5WorkspaceTopBar.disabledOpacity)
        .help(help)
    }
}

private extension View {
    func measureWorkspaceTopBarHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WorkspaceTopBarHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    func glassCapsule() -> some View {
        modifier(GlassChromeModifier(shape: Capsule()))
    }

    func glassCircle() -> some View {
        modifier(GlassChromeModifier(shape: Circle()))
            .frame(width: L5WorkspaceTopBar.controlDiameter, height: L5WorkspaceTopBar.controlDiameter)
    }
}

private struct GlassChromeModifier<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.stroke(L5Color.border, lineWidth: L5WorkspaceTopBar.borderWidth)
            }
            .shadow(color: .black.opacity(L5WorkspaceTopBar.shadowOpacity), radius: L5Spacing.x4, x: .zero, y: L5Spacing.x1)
    }
}

private enum L5WorkspaceDashboardLayout {
    static let splitSpacing: CGFloat = .zero

    static func reservedWidth(for workspaceWidth: CGFloat) -> CGFloat {
        min(L5Spacing.x16 * 5.5, max(L5Spacing.x16 * 4.75, workspaceWidth / 3.5))
    }

    static func reservedContentInset(for workspaceWidth: CGFloat) -> CGFloat {
        reservedWidth(for: workspaceWidth) + L5Spacing.x6
    }

    static func reservedMaxHeight(for workspaceHeight: CGFloat) -> CGFloat {
        max(L5Spacing.x16 * 7, workspaceHeight - L5Spacing.x12)
    }

    static func overlayWidth(for workspaceWidth: CGFloat) -> CGFloat {
        min(L5Spacing.x16 * 5.5, max(L5Spacing.x16 * 4.5, workspaceWidth - L5Spacing.x10))
    }

    static func popoverMaxHeight(for workspaceHeight: CGFloat) -> CGFloat {
        min(workspaceHeight - L5Spacing.x16, L5Spacing.x16 * 9)
    }
}

private enum L5WorkspaceTopBar {
    static let leadingWindowControlsInset = L5Spacing.x16
    static let controlDiameter = L5Size.control
    static let verticalPadding = L5Spacing.x1
    static let fadeHeight = L5Spacing.x12
    static let fadeStart: CGFloat = .zero
    static let fadeMid = L5Spacing.x1 / L5Spacing.x10
    static let fadeEnd: CGFloat = 1
    static let fadeTintTopOpacity = L5Spacing.x4 / L5Spacing.x10
    static let fadeTintMidOpacity = L5Spacing.x2 / L5Spacing.x10
    static let borderWidth = L5Spacing.x1 / L5Spacing.x4
    static let shadowOpacity = L5Spacing.x1 / L5Spacing.x16
    static let disabledOpacity = L5Spacing.x6 / L5Spacing.x16

    static func scrollContentTopInset(for measuredHeight: CGFloat) -> CGFloat {
        max(measuredHeight, L5Spacing.x10) + L5Spacing.x4
    }

    static func floatingSurfaceTopInset(for measuredHeight: CGFloat) -> CGFloat {
        scrollContentTopInset(for: measuredHeight)
    }
}

private struct WorkspaceTopBarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
