import Level5Design
import SwiftUI

struct TranscriptView: View {
    let items: [LocalTranscriptItem]
    let followsTail: Bool
    let setFollowsTail: (Bool) -> Void

    private let bottomID = "transcript-bottom"
    private let coordinateSpaceName = "transcript-scroll"
    private let bottomThreshold: CGFloat = 24

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: L5Spacing.x4) {
                        ForEach(items) { item in
                            TranscriptRow(item: item)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .background {
                                GeometryReader { bottomProxy in
                                    Color.clear.preference(
                                        key: TranscriptBottomPreferenceKey.self,
                                        value: bottomProxy.frame(in: .named(coordinateSpaceName)).maxY
                                    )
                                }
                            }
                    }
                    .padding(L5Spacing.x6)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: coordinateSpaceName)
                .scrollContentBackground(.hidden)
                .onAppear {
                    guard followsTail else { return }
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: transcriptVersion) { _, _ in
                    guard followsTail else { return }
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: followsTail) { _, newValue in
                    guard newValue else { return }
                    scrollToBottom(proxy, animated: true)
                }
                .onPreferenceChange(TranscriptBottomPreferenceKey.self) { bottomY in
                    guard viewport.size.height > 0 else { return }
                    let isAtBottom = bottomY <= viewport.size.height + bottomThreshold
                    guard isAtBottom != followsTail else { return }
                    setFollowsTail(isAtBottom)
                }
            }
        }
    }

    private var transcriptVersion: String {
        items
            .map { "\($0.id.uuidString):\($0.text.count)" }
            .joined(separator: "|")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.18), action)
        } else {
            action()
        }
    }
}

private struct TranscriptBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TranscriptRow: View {
    let item: LocalTranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: L5Spacing.x3) {
            roleIcon
                .frame(width: 26, height: 26)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: L5Spacing.x1) {
                Text(roleTitle)
                    .font(L5Font.caption)
                    .foregroundStyle(.secondary)

                Text(item.text)
                    .font(L5Font.body)
                    .foregroundStyle(L5Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(L5Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(L5Color.border, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var roleIcon: some View {
        switch item.role {
        case .user:
            Image(systemName: "person.fill")
                .foregroundStyle(.white)
        case .agent:
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
        case .status:
            Image(systemName: "info")
                .foregroundStyle(.secondary)
        }
    }

    private var roleTitle: String {
        switch item.role {
        case .user: "You"
        case .agent: "Agent"
        case .status: "Status"
        }
    }

    private var iconBackground: Color {
        switch item.role {
        case .user: L5Color.accent
        case .agent: Color(nsColor: .systemGreen)
        case .status: L5Color.secondaryBackground
        }
    }

    private var rowMaterial: Material {
        switch item.role {
        case .user: .regularMaterial
        case .agent: .regularMaterial
        case .status: .thinMaterial
        }
    }
}
