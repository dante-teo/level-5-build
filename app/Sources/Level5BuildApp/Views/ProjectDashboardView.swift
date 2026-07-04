import Level5Core
import Level5Design
import SwiftUI

struct ProjectDashboardView: View {
    let state: ProjectDashboardState
    let plan: AgentPlanState?
    let refreshAction: () -> Void
    let closeAction: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .vertical) {
            panel(scrolls: false)
            panel(scrolls: true)
        }
    }

    private func panel(scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: L5Spacing.x5) {
            header

            if scrolls {
                ScrollView {
                    dashboardContent
                }
                .scrollIndicators(.automatic)
            } else {
                dashboardContent
            }
        }
        .padding(L5Spacing.x5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: L5Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: L5Radius.panel, style: .continuous)
                .stroke(L5Color.border, lineWidth: L5DashboardStyle.borderWidth)
        }
        .shadow(color: .black.opacity(L5DashboardStyle.shadowOpacity), radius: L5Spacing.x6, x: .zero, y: L5Spacing.x2)
    }

    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x4) {
            environmentRows
            Divider()
            planSection
            sourcesSection
        }
        .padding(.bottom, L5Spacing.x2)
    }

    private var header: some View {
        HStack(spacing: L5Spacing.x2) {
            Text("Environment")
                .font(L5Font.h3)
                .foregroundStyle(L5Color.textSecondary)

            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            }

            Spacer()

            Button(action: refreshAction) {
                Image(systemName: "gearshape")
                    .frame(width: L5Size.action, height: L5Size.action)
            }
            .buttonStyle(.plain)
            .help("Refresh project status")

            if let closeAction {
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .frame(width: L5Size.action, height: L5Size.action)
                }
                .buttonStyle(.plain)
                .help("Close project dashboard")
            }
        }
    }

    private var environmentRows: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x4) {
            EnvironmentRow(icon: "plus.rectangle", title: "Changes") {
                HStack(spacing: L5Spacing.x2) {
                    if state.gitStatus.isAvailable {
                        Text("+\(state.gitStatus.additions.formatted())")
                            .foregroundStyle(L5Color.success)
                        Text("-\(state.gitStatus.deletions.formatted())")
                            .foregroundStyle(L5Color.danger)
                    } else {
                        Text("Unavailable")
                            .foregroundStyle(L5Color.textMuted)
                    }
                }
                .font(L5Font.body.weight(.semibold))
            }

            EnvironmentRow(icon: "laptopcomputer", title: "Local") {
                Image(systemName: "chevron.down")
                    .font(L5Font.caption)
                    .foregroundStyle(L5Color.textMuted)
            }

            EnvironmentRow(icon: "point.3.connected.trianglepath.dotted", title: branchTitle) {
                Image(systemName: "chevron.down")
                    .font(L5Font.caption)
                    .foregroundStyle(L5Color.textMuted)
            }
            .help(state.gitStatus.root ?? state.projectPath)

            EnvironmentRow(icon: "smallcircle.filled.circle", title: "Commit or push")

            EnvironmentRow(icon: "globe", title: "Create pull request")
        }
    }

    private var branchTitle: String {
        guard state.gitStatus.isAvailable else { return "No git" }
        return state.gitStatus.branch ?? "HEAD"
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x4) {
            Text("Sources")
                .font(L5Font.h3)
                .foregroundStyle(L5Color.textSecondary)

            if state.references.isEmpty {
                Text("No sources yet")
                    .font(L5Font.h3)
                    .foregroundStyle(L5Color.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: L5Spacing.x3) {
                    ForEach(state.references) { reference in
                        EnvironmentRow(
                            icon: reference.kind == .web ? "link" : "doc",
                            title: reference.title
                        ) {
                            EmptyView()
                        }
                        .help(reference.uri)
                    }
                }
            }
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x3) {
            Text("Plan")
                .font(L5Font.h3)
                .foregroundStyle(L5Color.textSecondary)

            if let plan, !plan.entries.isEmpty {
                VStack(alignment: .leading, spacing: L5Spacing.x3) {
                    ForEach(plan.entries) { entry in
                        HStack(alignment: .top, spacing: L5Spacing.x2) {
                            Circle()
                                .fill(color(for: entry.status))
                                .frame(width: L5Size.icon / 2, height: L5Size.icon / 2)
                                .padding(.top, L5Spacing.x1)
                            VStack(alignment: .leading, spacing: L5Spacing.x1) {
                                Text(entry.content)
                                    .font(L5Font.caption)
                                    .foregroundStyle(L5Color.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(AgentTranscriptStatusNormalizer.display(entry.status) ?? entry.status)
                                    .font(L5Font.caption)
                                    .foregroundStyle(L5Color.textMuted)
                            }
                        }
                    }
                }
            } else {
                Text("No active plan")
                    .font(L5Font.h3)
                    .foregroundStyle(L5Color.textSecondary)
            }
        }
    }

    private func color(for status: String) -> Color {
        switch AgentTranscriptStatusNormalizer.normalized(status) {
        case "completed":
            L5Color.success
        case "in_progress":
            L5Color.accent
        case "failed":
            L5Color.danger
        default:
            L5Color.textMuted
        }
    }
}

private struct EnvironmentRow<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var trailing: Trailing

    init(icon: String, title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: L5Spacing.x4) {
            Image(systemName: icon)
                .font(L5Font.h3)
                .foregroundStyle(L5Color.textPrimary)
                .frame(width: L5Size.control, alignment: .center)

            Text(title)
                .font(L5Font.h3)
                .foregroundStyle(L5Color.textPrimary)
                .lineLimit(2)

            Spacer(minLength: L5Spacing.x3)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum L5DashboardStyle {
    static let borderWidth = L5Spacing.x1 / L5Spacing.x4
    static let shadowOpacity = L5Spacing.x1 / L5Spacing.x16
}
