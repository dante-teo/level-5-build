import Level5Design
import SwiftUI

struct ShellSidebarView: View {
    let sessions: [AgentSessionRow]
    let activeSessionId: String?
    let hasMoreSessions: Bool
    let newChatAction: () -> Void
    let selectSessionAction: (String) -> Void
    let loadMoreSessionsAction: () -> Void
    let deleteSessionAction: (String) -> Void

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
                if sessions.isEmpty {
                    Text("No saved chats yet")
                        .font(L5Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, L5Spacing.x1)
                } else {
                    ForEach(sessions) { session in
                        SidebarSessionRow(
                            session: session,
                            isActive: session.sessionId == activeSessionId,
                            selectAction: {
                                selectSessionAction(session.sessionId)
                            },
                            deleteAction: {
                                deleteSessionAction(session.sessionId)
                            }
                        )
                    }
                }

                if hasMoreSessions {
                    Button(action: loadMoreSessionsAction) {
                        Label("Load More", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.plain)
                }
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

private struct SidebarSessionRow: View {
    let session: AgentSessionRow
    let isActive: Bool
    let selectAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: L5Spacing.x2) {
            Button(action: selectAction) {
                HStack(spacing: L5Spacing.x3) {
                    Image(systemName: session.isRunning ? "circle.dotted" : "bubble.left")
                        .foregroundStyle(session.isRunning ? L5Color.accent : .secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .lineLimit(1)

                        Text(session.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isActive ? L5Color.accent : L5Color.textPrimary)

            Button(action: deleteAction) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete")
        }
    }
}
