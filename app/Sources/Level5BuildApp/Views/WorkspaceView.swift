import Level5Core
import Level5Design
import SwiftUI

struct WorkspaceView: View {
    let transcript: [LocalTranscriptItem]
    @Binding var draft: String
    let selectedProject: RecentProject?
    let recentProjects: [RecentProject]
    var isComposerFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void
    let selectProjectAction: (URL) -> Void
    let clearProjectAction: () -> Void
    let removeRecentProjectAction: (RecentProject) -> Void
    let validateProjectAction: (RecentProject) -> Bool

    var body: some View {
        Group {
            if transcript.isEmpty {
                NewSessionView(
                    draft: $draft,
                    selectedProject: selectedProject,
                    recentProjects: recentProjects,
                    isComposerFocused: isComposerFocused,
                    sendAction: sendAction,
                    selectProjectAction: selectProjectAction,
                    clearProjectAction: clearProjectAction,
                    removeRecentProjectAction: removeRecentProjectAction,
                    validateProjectAction: validateProjectAction
                )
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        TranscriptView(items: transcript)

                        ComposerView(
                            draft: $draft,
                            isNewSession: false,
                            selectedProject: selectedProject,
                            recentProjects: recentProjects,
                            isFocused: isComposerFocused,
                            sendAction: sendAction,
                            selectProjectAction: selectProjectAction,
                            clearProjectAction: clearProjectAction,
                            removeRecentProjectAction: removeRecentProjectAction,
                            validateProjectAction: validateProjectAction
                        )
                        .frame(maxWidth: 900)
                        .padding(.horizontal, L5Spacing.x6)
                        .padding(.bottom, L5Spacing.x5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Color.clear
                        .frame(width: 0)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(L5Color.background)
    }
}

private struct NewSessionView: View {
    @Binding var draft: String
    let selectedProject: RecentProject?
    let recentProjects: [RecentProject]
    var isComposerFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void
    let selectProjectAction: (URL) -> Void
    let clearProjectAction: () -> Void
    let removeRecentProjectAction: (RecentProject) -> Void
    let validateProjectAction: (RecentProject) -> Bool

    var body: some View {
        VStack(spacing: L5Spacing.x8) {
            Spacer(minLength: L5Spacing.x16)

            VStack(spacing: L5Spacing.x8) {
                Text(title)
                    .font(L5Font.h2)
                    .foregroundStyle(L5Color.textPrimary)
                    .multilineTextAlignment(.center)

                ComposerView(
                    draft: $draft,
                    isNewSession: true,
                    selectedProject: selectedProject,
                    recentProjects: recentProjects,
                    isFocused: isComposerFocused,
                    sendAction: sendAction,
                    selectProjectAction: selectProjectAction,
                    clearProjectAction: clearProjectAction,
                    removeRecentProjectAction: removeRecentProjectAction,
                    validateProjectAction: validateProjectAction
                )
            }
            .frame(maxWidth: 760)

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
