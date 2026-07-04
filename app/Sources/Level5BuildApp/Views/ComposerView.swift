import AppKit
import Level5Core
import Level5Design
import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let isNewSession: Bool
    let selectedProject: RecentProject?
    let recentProjects: [RecentProject]
    var isFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void
    let selectProjectAction: (URL) -> Void
    let clearProjectAction: () -> Void
    let removeRecentProjectAction: (RecentProject) -> Void
    let validateProjectAction: (RecentProject) -> Bool

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
                ComposerContextFooter(
                    selectedProject: selectedProject,
                    recentProjects: recentProjects,
                    selectProjectAction: selectProjectAction,
                    clearProjectAction: clearProjectAction,
                    removeRecentProjectAction: removeRecentProjectAction,
                    validateProjectAction: validateProjectAction
                )
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
    let selectedProject: RecentProject?
    let recentProjects: [RecentProject]
    let selectProjectAction: (URL) -> Void
    let clearProjectAction: () -> Void
    let removeRecentProjectAction: (RecentProject) -> Void
    let validateProjectAction: (RecentProject) -> Bool
    @State private var isProjectPickerPresented = false

    var body: some View {
        HStack(spacing: L5Spacing.x8) {
            Button {
                isProjectPickerPresented.toggle()
            } label: {
                FooterItem(title: projectTitle, systemImage: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(L5Color.textPrimary)
            .popover(isPresented: $isProjectPickerPresented, arrowEdge: .bottom) {
                ProjectPickerPopover(
                    selectedProject: selectedProject,
                    recentProjects: recentProjects,
                    selectProjectAction: { url in
                        selectProjectAction(url)
                        isProjectPickerPresented = false
                    },
                    clearProjectAction: {
                        clearProjectAction()
                        isProjectPickerPresented = false
                    },
                    removeRecentProjectAction: removeRecentProjectAction,
                    validateProjectAction: validateProjectAction
                )
            }

            FooterItem(title: "macos", systemImage: "point.3.connected.trianglepath.dotted")

            Spacer()
        }
        .font(L5Font.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, L5Spacing.x5)
        .padding(.top, L5Spacing.x4)
        .padding(.bottom, L5Spacing.x5)
    }

    private var projectTitle: String {
        selectedProject?.displayName ?? "Choose project"
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

private struct ProjectPickerPopover: View {
    let selectedProject: RecentProject?
    let recentProjects: [RecentProject]
    let selectProjectAction: (URL) -> Void
    let clearProjectAction: () -> Void
    let removeRecentProjectAction: (RecentProject) -> Void
    let validateProjectAction: (RecentProject) -> Bool
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x3) {
            TextField("Search projects", text: $searchText)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: L5Spacing.x1) {
                ForEach(filteredProjects, id: \.path) { project in
                    RecentProjectRow(
                        project: project,
                        isSelected: project.path == selectedProject?.path,
                        isValid: validateProjectAction(project),
                        selectAction: {
                            selectProjectAction(URL(fileURLWithPath: project.path, isDirectory: true))
                        },
                        removeAction: {
                            removeRecentProjectAction(project)
                        }
                    )
                }

                if filteredProjects.isEmpty {
                    Text("No recent projects")
                        .font(L5Font.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, L5Spacing.x2)
                }
            }

            Divider()

            PickerCommandButton(title: "New project", systemImage: "folder.badge.plus") {
                if let url = ProjectFolderPanel.chooseDirectory() {
                    selectProjectAction(url)
                }
            }

            PickerCommandButton(title: "Don't work in a project", systemImage: "nosign") {
                clearProjectAction()
            }
        }
        .padding(L5Spacing.x4)
        .frame(width: 360)
    }

    private var filteredProjects: [RecentProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recentProjects }

        return recentProjects.filter { project in
            project.displayName.localizedCaseInsensitiveContains(query)
                || project.path.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct RecentProjectRow: View {
    let project: RecentProject
    let isSelected: Bool
    let isValid: Bool
    let selectAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: L5Spacing.x2) {
            Button(action: selectAction) {
                HStack(spacing: L5Spacing.x3) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "folder")
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: L5Spacing.x2) {
                            Text(project.displayName)
                                .lineLimit(1)

                            if !isValid {
                                Text("Missing")
                                    .font(L5Font.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(project.path)
                            .font(L5Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.48)

            Button(action: removeAction) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
        .padding(.vertical, L5Spacing.x2)
    }
}

private struct PickerCommandButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: L5Spacing.x3) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(L5Color.textPrimary)
    }
}

private enum ProjectFolderPanel {
    @MainActor
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "Choose Project"
        panel.prompt = "Choose"

        return panel.runModal() == .OK ? panel.url : nil
    }
}
