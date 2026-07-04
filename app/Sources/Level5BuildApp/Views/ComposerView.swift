import Level5Design
import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let isNewSession: Bool
    var isFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: L5Spacing.x3) {
                TextField("Do anything", text: $draft, axis: .vertical)
                    .font(L5Font.body)
                    .textFieldStyle(.plain)
                    .focused(isFocused)
                    .lineLimit(isNewSession ? 1...6 : 1...5)
                    .frame(minHeight: isNewSession ? 70 : 54, alignment: .topLeading)

                HStack(spacing: L5Spacing.x3) {
                    Spacer()

                    SendButton(
                        isEnabled: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: sendAction
                    )
                }
            }
            .padding(.horizontal, isNewSession ? L5Spacing.x4 : L5Spacing.x4)
            .padding(.top, isNewSession ? L5Spacing.x4 : L5Spacing.x4)
            .padding(.bottom, isNewSession ? L5Spacing.x4 : L5Spacing.x4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isNewSession ? L5Radius.panel : 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: isNewSession ? L5Radius.panel : 8, style: .continuous)
                    .stroke(L5Color.border, lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(isNewSession ? 0.12 : 0),
                radius: isNewSession ? 28 : 0,
                x: 0,
                y: isNewSession ? 18 : 0
            )

            if isNewSession {
                ComposerContextFooter()
            }
        }
        .background {
            if isNewSession {
                RoundedRectangle(cornerRadius: L5Radius.panel, style: .continuous)
                    .fill(L5Color.secondaryBackground.opacity(0.72))
                    .padding(.top, 82)
            }
        }
    }
}

private struct SendButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .background(sendBackground, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
        .help("Send")
    }

    private var sendBackground: Color {
        isEnabled ? L5Color.accent : Color(nsColor: .tertiaryLabelColor)
    }
}

private struct ComposerContextFooter: View {
    var body: some View {
        HStack(spacing: L5Spacing.x8) {
            FooterItem(title: "level-5-build", systemImage: "list.bullet.rectangle")
                .foregroundStyle(L5Color.textPrimary)

            FooterItem(title: "macos", systemImage: "point.3.connected.trianglepath.dotted")

            Spacer()
        }
        .font(L5Font.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, L5Spacing.x5)
        .padding(.top, L5Spacing.x4)
        .padding(.bottom, L5Spacing.x5)
    }
}

private struct FooterItem: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: L5Spacing.x2) {
            Image(systemName: systemImage)
                .frame(width: 18)

            Text(title)
                .lineLimit(1)
        }
    }
}
