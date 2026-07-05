import Level5Core
import Level5Design
import AppKit
import SwiftUI

public struct ContentView: View {
    @AppStorage("shell.sidebar.isCollapsed") private var isSidebarCollapsed = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var model: AgentSessionModel
    @State private var recentProjects: [RecentProject] = []
    @State private var reviewPaneWidth: CGFloat = Self.defaultReviewPaneWidth
    @State private var reviewFilter = ""
    private let recentProjectStore: RecentProjectStore?
    @FocusState private var isComposerFocused: Bool
    private static let minWorkspaceWidth: CGFloat = 520
    private static let minReviewPaneWidth: CGFloat = 420
    private static let defaultReviewPaneWidth: CGFloat = 600
    private static let maxReviewPaneWidth: CGFloat = 820
    fileprivate static let reviewPaneResizeHandleWidth: CGFloat = 18

    /// Both stores default to sharing the single `Level5Database` connection
    /// at the ADR-mandated path (`~/.level5build/level5.sqlite`): GRDB
    /// recommends one writer connection per file, and two independent
    /// `DatabaseQueue`s to the same file would work but buy nothing here.
    /// The shared default is lazy and computed once per process, so callers
    /// that want no on-disk persistence (e.g. tests) should pass `nil` for
    /// both parameters explicitly rather than relying on only one default
    /// being skipped.
    public static let defaultDatabase: Level5Database? = try? Level5Database(
        migrations: RecentProjectStore.migrations + SessionPersistenceStore.migrations
    )

    public init(
        recentProjectStore: RecentProjectStore? = ContentView.defaultDatabase.map { RecentProjectStore(database: $0) },
        persistenceStore: SessionPersistenceStore? = ContentView.defaultDatabase.map { SessionPersistenceStore(database: $0) }
    ) {
        self.recentProjectStore = recentProjectStore
        _model = State(wrappedValue: AgentSessionModel(persistenceStore: persistenceStore))
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebarView(
                sessions: model.sessions,
                activeSessionId: model.activeSessionId,
                newChatAction: startNewChat,
                selectSessionAction: selectSession,
                deleteSessionAction: model.deleteSession
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            GeometryReader { geometry in
                let showsReviewToggle = shouldShowReviewToggle(detailWidth: geometry.size.width)
                HStack(spacing: 0) {
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
                        isReviewAvailable: showsReviewToggle,
                        isReviewVisible: model.reviewState.isOpen,
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
                        toggleReviewAction: { toggleReview(detailWidth: geometry.size.width) },
                        removeQueuedPromptAction: model.removeQueuedPrompt,
                        selectProjectAction: selectProject,
                        clearProjectAction: clearSelectedProject,
                        removeRecentProjectAction: removeRecentProject,
                        validateProjectAction: validateProject
                    )
                    .frame(minWidth: 520)

                    if model.reviewState.isOpen {
                        ReviewPaneResizeHandle(
                            width: $reviewPaneWidth,
                            minWidth: Self.minReviewPaneWidth,
                            maxWidth: Self.maxReviewPaneWidth
                        )
                        .zIndex(2)
                        ReviewPaneView(
                            state: model.reviewState,
                            filterText: $reviewFilter,
                            isAgentRunning: model.isActiveSessionRunning,
                            refreshAction: model.refreshReview,
                            closeAction: model.closeReview,
                            loadPreviewAction: model.loadReviewPreview
                        )
                        .frame(width: reviewPaneWidth)
                        .layoutPriority(1)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
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

    private func toggleReview(detailWidth: CGFloat) {
        if model.reviewState.isOpen {
            model.closeReview()
            reviewFilter = ""
            reviewPaneWidth = Self.defaultReviewPaneWidth
            return
        }
        guard model.isReviewAvailable else { return }
        if columnVisibility != .detailOnly, detailWidth < Self.requiredReviewWidth(reviewPaneWidth: Self.defaultReviewPaneWidth) {
            columnVisibility = .detailOnly
        }
        reviewPaneWidth = Self.defaultReviewPaneWidth
        model.openReview()
    }

    private func shouldShowReviewToggle(detailWidth: CGFloat) -> Bool {
        guard model.isReviewAvailable else { return false }
        let availableWidth = columnVisibility == .detailOnly ? detailWidth : detailWidth + 300
        return availableWidth >= Self.requiredReviewWidth(reviewPaneWidth: Self.defaultReviewPaneWidth)
    }

    private static func requiredReviewWidth(reviewPaneWidth: CGFloat) -> CGFloat {
        minWorkspaceWidth + reviewPaneResizeHandleWidth + reviewPaneWidth
    }
}

private struct ReviewPaneResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isHovering ? Color.accentColor.opacity(0.16) : Color.clear)
            Rectangle()
                .fill(isHovering ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.28))
                .frame(width: isHovering ? 2 : 1)
        }
        .frame(width: ContentView.reviewPaneResizeHandleWidth)
        .contentShape(Rectangle())
        .background(WindowDragExclusionView())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let startWidth = dragStartWidth ?? width
                    dragStartWidth = startWidth
                    width = min(maxWidth, max(minWidth, startWidth - value.translation.width))
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct WindowDragExclusionView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NonDraggableNSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class NonDraggableNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
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
