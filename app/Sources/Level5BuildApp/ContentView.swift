import Level5Core
import AppKit
import SwiftUI

public struct ContentView: View {
    @AppStorage("shell.sidebar.isCollapsed") private var isSidebarCollapsed = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var model = AgentSessionModel()
    @State private var recentProjects: [RecentProject] = []
    private let recentProjectStore: RecentProjectStore?
    @FocusState private var isComposerFocused: Bool

    public init(recentProjectStore: RecentProjectStore? = try? RecentProjectStore()) {
        self.recentProjectStore = recentProjectStore
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebarView(
                sessions: model.sessions,
                activeSessionId: model.activeSessionId,
                hasMoreSessions: model.nextCursor != nil,
                newChatAction: startNewChat,
                selectSessionAction: selectSession,
                loadMoreSessionsAction: model.loadMoreSessions,
                deleteSessionAction: model.deleteSession
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            WorkspaceView(
                transcript: model.transcript,
                activeSessionId: model.activeSessionId,
                transcriptFollowsTail: model.activeTranscriptFollowsTail,
                availability: model.availability,
                runtimeMessage: model.runtimeMessage,
                queuedPrompts: model.activeQueue,
                plan: model.activePlan,
                usage: model.activeUsage,
                dashboard: model.dashboardState,
                draft: $model.draft,
                modelOptions: model.modelOptions,
                slashCommands: model.slashCommands,
                approvalMode: model.approvalMode,
                pendingPermissionRequest: model.activePermissionRequest,
                isActiveSessionRunning: model.isActiveSessionRunning,
                isModelSaveInFlight: model.sessionModelSaveInFlight,
                selectedProject: model.selectedProject,
                recentProjects: recentProjects,
                canSendWithButton: model.canSendWithButton,
                canEditComposer: model.canEditComposer,
                isComposerFocused: $isComposerFocused,
                sendAction: sendDraft,
                cancelAction: model.cancelActiveTurn,
                selectModelAction: model.selectModel,
                selectApprovalModeAction: model.selectApprovalMode,
                respondToPermissionAction: model.respondToPermission,
                rejectPermissionWithInstructionsAction: model.rejectPermissionWithInstructions,
                addAttachmentsAction: model.addAttachments,
                removeAttachmentAction: model.removeAttachment,
                acceptSlashCommandAction: model.acceptSlashCommand,
                setTranscriptFollowsTailAction: model.setActiveTranscriptFollowsTail,
                refreshDashboardAction: model.refreshProjectDashboard,
                removeQueuedPromptAction: model.removeQueuedPrompt,
                selectProjectAction: selectProject,
                clearProjectAction: clearSelectedProject,
                removeRecentProjectAction: removeRecentProject,
                validateProjectAction: validateProject
            )
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Level5 Build")
        .level5WindowChrome()
        .background(WindowChromeConfigurator())
        .onAppear {
            columnVisibility = isSidebarCollapsed ? .detailOnly : .all
            loadRecentProjects()
            model.start()
        }
        .onChange(of: columnVisibility) { _, visibility in
            isSidebarCollapsed = visibility == .detailOnly
        }
        .focusedValue(\.shellCommands, ShellCommands(
            newChat: startNewChat,
            toggleSidebar: toggleSidebar,
            focusComposer: focusComposer,
            clearTranscript: clearTranscript
        ))
    }

    private func startNewChat() {
        model.startNewChat()
        focusComposer()
    }

    private func sendDraft() {
        model.sendDraft()
    }

    private func selectSession(_ sessionId: String) {
        model.selectSession(sessionId)
        focusComposer()
    }

    private func selectProject(_ url: URL) {
        guard let recentProjectStore else { return }

        do {
            let project = try recentProjectStore.upsertSelectedFolder(at: url)
            model.selectProject(project)
            loadRecentProjects()
        } catch {
            assertionFailure("Failed to select project: \(error)")
        }
    }

    private func clearSelectedProject() {
        model.clearSelectedProject()
    }

    private func removeRecentProject(_ project: RecentProject) {
        guard let recentProjectStore else { return }

        do {
            try recentProjectStore.removeRecentProject(path: project.path)
            if model.selectedProjectPath == project.path {
                model.clearSelectedProject()
            }
            loadRecentProjects()
        } catch {
            assertionFailure("Failed to remove recent project: \(error)")
        }
    }

    private func validateProject(_ project: RecentProject) -> Bool {
        recentProjectStore?.validateDirectoryExistence(path: project.path).exists ?? false
    }

    private func loadRecentProjects() {
        guard let recentProjectStore else { return }

        do {
            recentProjects = try recentProjectStore.listRecentProjects()
            model.setRecentProjects(recentProjects)
        } catch {
            assertionFailure("Failed to load recent projects: \(error)")
        }
    }

    private func clearTranscript() {
        model.clearTranscript()
    }

    private func focusComposer() {
        isComposerFocused = true
    }

    private func toggleSidebar() {
        if columnVisibility == .detailOnly {
            columnVisibility = .all
        } else {
            columnVisibility = .detailOnly
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWhenAttached(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWhenAttached(view)
    }

    private func configureWhenAttached(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unifiedCompact
            window.toolbar?.showsBaselineSeparator = false
            window.isMovableByWindowBackground = true
        }
    }
}

private extension View {
    @ViewBuilder
    func level5WindowChrome() -> some View {
        if #available(macOS 15.0, *) {
            self
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
