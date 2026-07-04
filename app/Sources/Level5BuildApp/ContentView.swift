import SwiftUI

public struct ContentView: View {
    @AppStorage("shell.sidebar.isCollapsed") private var isSidebarCollapsed = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var model = LocalShellModel()
    @FocusState private var isComposerFocused: Bool

    public init() {}

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
                isComposerFocused: $isComposerFocused,
                sendAction: sendDraft
            )
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Level5 Build")
        .onAppear {
            columnVisibility = isSidebarCollapsed ? .detailOnly : .all
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
        _ = model.sendDraft()
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
