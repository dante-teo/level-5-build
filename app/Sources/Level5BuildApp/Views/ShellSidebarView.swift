import AppKit
import Level5Design
import SwiftUI

struct ShellSidebarView: View {
    let sessions: [AgentSessionRow]
    let activeSessionId: String?
    let newChatAction: () -> Void
    let selectSessionAction: (String) -> Void
    let deleteSessionAction: (String) -> Void

    var body: some View {
        List {
            Section {
                Level5IdentityHeader()
                    .listRowInsets(EdgeInsets(top: L5Spacing.x3, leading: L5Spacing.x3, bottom: L5Spacing.x3, trailing: L5Spacing.x3))

                Button(action: newChatAction) {
                    Label {
                        Text("New Chat")
                    } icon: {
                        L5IconView(.newChat)
                    }
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
            }

            Section {
                Button {} label: {
                    Label {
                        Text("Settings")
                    } icon: {
                        L5IconView(.settings)
                    }
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
                .clipShape(RoundedRectangle(cornerRadius: L5Radius.small, style: .continuous))

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
                .frame(width: L5Size.icon)

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
        Button(action: selectAction) {
            HStack(spacing: L5Spacing.x3) {
                L5IconView(.chat)
                    .foregroundStyle(isActive ? L5Color.accent : .secondary)
                    .frame(width: L5Size.icon)

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

                sessionStateIndicator
                    .frame(width: L5Size.icon)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? L5Color.accent : L5Color.textPrimary)
        .contextMenu {
            Button("Delete Chat...", role: .destructive) {
                confirmDelete()
            }
        }
    }

    @ViewBuilder
    private var sessionStateIndicator: some View {
        if session.isAwaitingPermission {
            L5IconView(.awaitingPermission, size: 11)
                .foregroundStyle(L5Color.warning)
        } else if session.isRunning {
            L5IconView(.running, size: 11)
                .foregroundStyle(L5Color.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: true)
        } else if session.hasCompletedTurn {
            L5IconView(.completed, size: 11)
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else {
            Color.clear
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete Chat?"
        alert.informativeText = "This removes the chat from Level5 Build and the agent runtime. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let deleteButton = alert.buttons.first
        deleteButton?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            deleteAction()
        }
    }
}
