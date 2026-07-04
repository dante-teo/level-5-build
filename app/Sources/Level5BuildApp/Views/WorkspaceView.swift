import Level5Design
import SwiftUI

struct WorkspaceView: View {
    let transcript: [LocalTranscriptItem]
    @Binding var draft: String
    var isComposerFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void

    var body: some View {
        Group {
            if transcript.isEmpty {
                NewSessionView(
                    draft: $draft,
                    isComposerFocused: isComposerFocused,
                    sendAction: sendAction
                )
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        TranscriptView(items: transcript)

                        ComposerView(
                            draft: $draft,
                            isNewSession: false,
                            isFocused: isComposerFocused,
                            sendAction: sendAction
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
    var isComposerFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void

    var body: some View {
        VStack(spacing: L5Spacing.x8) {
            Spacer(minLength: L5Spacing.x16)

            VStack(spacing: L5Spacing.x8) {
                Text("What should we build in level-5-build?")
                    .font(L5Font.h2)
                    .foregroundStyle(L5Color.textPrimary)
                    .multilineTextAlignment(.center)

                ComposerView(
                    draft: $draft,
                    isNewSession: true,
                    isFocused: isComposerFocused,
                    sendAction: sendAction
                )
            }
            .frame(maxWidth: 760)

            Spacer(minLength: L5Spacing.x16)
        }
        .padding(.horizontal, L5Spacing.x8)
        .padding(.bottom, L5Spacing.x16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
