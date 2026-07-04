import Level5Core
import SwiftUI

public struct ContentView: View {
    @AppStorage("shell.sidebar.isCollapsed") private var isSidebarCollapsed = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var model = LocalShellModel()
    @State private var mockRuntime = MockAcpRuntime()
    @State private var recentProjects: [RecentProject] = []
    private let recentProjectStore: RecentProjectStore?
    @FocusState private var isComposerFocused: Bool

    public init(recentProjectStore: RecentProjectStore? = try? RecentProjectStore()) {
        self.recentProjectStore = recentProjectStore
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebarView(
                newChatAction: startNewChat
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            WorkspaceView(
                transcript: model.transcript,
                draft: $model.draft,
                selectedProject: model.selectedProject,
                recentProjects: recentProjects,
                isComposerFocused: $isComposerFocused,
                sendAction: sendDraft,
                selectProjectAction: selectProject,
                clearProjectAction: clearSelectedProject,
                removeRecentProjectAction: removeRecentProject,
                validateProjectAction: validateProject
            )
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Level5 Build")
        .onAppear {
            columnVisibility = isSidebarCollapsed ? .detailOnly : .all
            loadRecentProjects()
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
        mockRuntime.reset()
        focusComposer()
    }

    private func sendDraft() {
        if mockRuntime.isEnabled {
            guard let message = model.submitDraft() else { return }
            model.appendStatus("Sending to ACP mock...")
            let cwd = model.selectedProjectPath
            Task {
                await mockRuntime.send(
                    prompt: message,
                    cwd: cwd,
                    appendAgentText: { text in
                        model.appendAgentText(text)
                    },
                    appendStatus: { text in
                        model.appendStatus(text)
                    }
                )
            }
        } else {
            _ = model.sendDraft()
        }
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
