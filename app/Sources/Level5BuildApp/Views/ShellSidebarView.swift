import Level5Design
import SwiftUI

struct ShellSidebarView: View {
    let newChatAction: () -> Void

    var body: some View {
        List {
            Section {
                Level5IdentityHeader()
                    .listRowInsets(EdgeInsets(top: L5Spacing.x3, leading: L5Spacing.x3, bottom: L5Spacing.x3, trailing: L5Spacing.x3))

                Button(action: newChatAction) {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
            }

            Section("Chats") {
                SidebarRow(
                    title: "All chats",
                    systemImage: "bubble.left.and.bubble.right",
                    detail: "No saved chats yet"
                )

                Text("Start with New Chat. Messages you send here appear in the workspace.")
                    .font(L5Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, L5Spacing.x1)
            }

            Section {
                Button {} label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct Level5IdentityHeader: View {
    var body: some View {
        HStack(spacing: L5Spacing.x3) {
            L5Asset.mark
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: L5Spacing.x1) {
                Text("Level5")
                    .font(L5Font.h3)
                    .foregroundStyle(L5Color.textPrimary)

                Text("Native workspace")
                    .font(L5Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, L5Spacing.x1)
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        HStack(spacing: L5Spacing.x3) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
