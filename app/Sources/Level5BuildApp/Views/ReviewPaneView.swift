import AppKit
import Level5Core
import Level5Design
import SwiftUI

struct ReviewPaneView: View {
    let state: ProjectReviewPaneState
    @Binding var filterText: String
    let isAgentRunning: Bool
    let refreshAction: () -> Void
    let closeAction: () -> Void
    let loadPreviewAction: (ProjectChangedFile) -> Void

    private var files: [ProjectChangedFile] {
        guard let snapshot = state.snapshot else { return [] }
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snapshot.files }
        return snapshot.files.filter {
            $0.path.localizedCaseInsensitiveContains(trimmed)
                || ($0.oldPath?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || $0.statusBadge.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if state.isRefreshing, state.snapshot == nil {
                loadingState
            } else if let snapshot = state.snapshot, !snapshot.isAvailable {
                errorState(snapshot.error)
            } else if let snapshot = state.snapshot, snapshot.totalChangedFiles == 0 {
                emptyState
            } else {
                content
            }
        }
        .background(DiffPalette.background)
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: L5Spacing.x3) {
                Text("Unstaged")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DiffPalette.primaryText)

                Text(countText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DiffPalette.primaryText)
                    .padding(.horizontal, L5Spacing.x2)
                    .frame(height: 24)
                    .background(DiffPalette.pill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DiffPalette.primaryText)

                Text(additionsText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DiffPalette.addedLineNumber)

                Text(deletionsText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DiffPalette.deletedLineNumber)

                Spacer()

                if state.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }

                Button(action: refreshAction) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: L5Size.action, height: L5Size.action)
                }
                .buttonStyle(.plain)
                .help("Refresh")

                toolbarIcon("ellipsis", help: "More")
                toolbarIcon("arrow.up.arrow.down", help: "Sort")
                toolbarIcon("doc.viewfinder", help: "Inspect")
                toolbarIcon("folder", help: rootHint ?? "Project")

                ReviewPaneToggleButton(
                    isSelected: true,
                    action: closeAction
                )
            }
            .padding(.horizontal, L5Spacing.x4)
            .frame(height: 54)

            if isAgentRunning || !filterText.isEmpty {
                HStack(spacing: L5Spacing.x2) {
                    if isAgentRunning {
                        Label("Agent running; refresh after the turn for latest changes.", systemImage: "clock")
                    }
                    if !filterText.isEmpty {
                        TextField("Filter changed files", text: $filterText)
                            .textFieldStyle(.plain)
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(DiffPalette.mutedText)
                .padding(.horizontal, L5Spacing.x4)
                .padding(.bottom, L5Spacing.x2)
            }
        }
        .background(DiffPalette.header)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DiffPalette.separator)
                .frame(height: 1)
        }
    }

    private func toolbarIcon(_ systemName: String, help: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DiffPalette.mutedText)
            .frame(width: 30, height: 30)
            .help(help)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let overflowCount = state.snapshot?.overflowCount, overflowCount > 0 {
                Text("Showing first \(ProjectReviewService.fileLimit) files. \(overflowCount) more changed files are hidden.")
                    .font(L5Font.caption)
                    .foregroundStyle(L5Color.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, L5Spacing.x4)
                    .padding(.vertical, L5Spacing.x2)
                Divider()
            }

            if files.isEmpty {
                noResultsState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            ReviewFileDiffSection(
                                file: file,
                                preview: state.previewCache[file.id],
                                isLoading: state.loadingPreviewFileIDs.contains(file.id),
                                loadPreviewAction: loadPreviewAction
                            )
                        }
                    }
                }
                .background(DiffPalette.background)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: L5Spacing.x3) {
            ProgressView()
            Text("Loading Review")
                .font(L5Font.caption)
                .foregroundStyle(L5Color.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: L5Spacing.x3) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
            Text("No uncommitted changes")
                .font(L5Font.body.weight(.semibold))
            Text("Review shows Git working-tree changes only.")
                .font(L5Font.caption)
                .foregroundStyle(L5Color.textSecondary)
        }
        .foregroundStyle(L5Color.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(L5Spacing.x6)
    }

    private var noResultsState: some View {
        Text("No changed files match this filter.")
            .font(L5Font.caption)
            .foregroundStyle(L5Color.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(L5Spacing.x6)
    }

    private func errorState(_ error: ProjectReviewError?) -> some View {
        VStack(alignment: .leading, spacing: L5Spacing.x4) {
            Label(error?.message ?? "Review is unavailable.", systemImage: "exclamationmark.triangle")
                .font(L5Font.body.weight(.semibold))
                .foregroundStyle(L5Color.textPrimary)
            if let rawOutput = error?.rawOutput, !rawOutput.isEmpty {
                DisclosureGroup("Details") {
                    Text(rawOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, L5Spacing.x2)
                }
                .font(L5Font.caption)
            }
            Spacer()
        }
        .padding(L5Spacing.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summaryText: String {
        guard let snapshot = state.snapshot else { return "Working tree" }
        let count = snapshot.totalChangedFiles
        return count == 1 ? "1 changed file" : "\(count) changed files"
    }

    private var countText: String {
        guard let count = state.snapshot?.totalChangedFiles else { return "-" }
        return "\(count)"
    }

    private var additionsText: String {
        let additions = state.snapshot?.files.reduce(0) { $0 + $1.additions } ?? 0
        return "+\(additions.formatted())"
    }

    private var deletionsText: String {
        let deletions = state.snapshot?.files.reduce(0) { $0 + $1.deletions } ?? 0
        return "-\(deletions.formatted())"
    }

    private var rootHint: String? {
        guard let snapshot = state.snapshot else { return state.projectPath }
        let branch = snapshot.branch ?? "HEAD"
        if let root = snapshot.root {
            return "\(branch) - \(URL(fileURLWithPath: root).lastPathComponent)"
        }
        return branch
    }
}

private struct ReviewPreviewContent: View {
    let preview: ProjectFilePreview

    var body: some View {
        switch preview.content {
        case let .unifiedDiff(diff):
            DiffPreviewView(diff: diff, file: preview.file)
        case let .image(path, byteSize):
            ImagePreview(path: path, byteSize: byteSize)
        case let .metadata(message):
            MetadataPreview(systemImage: "info.circle", title: message)
        case let .tooLarge(byteSize, limit):
            MetadataPreview(systemImage: "doc.zipper", title: "Diff too large", subtitle: "\(byteSize.formatted()) bytes exceeds the \(limit.formatted()) byte preview limit.")
        case let .error(error):
            MetadataPreview(systemImage: "exclamationmark.triangle", title: error.message, subtitle: error.rawOutput)
        }
    }
}

private struct ReviewFileDiffSection: View {
    let file: ProjectChangedFile
    let preview: ProjectFilePreview?
    let isLoading: Bool
    let loadPreviewAction: (ProjectChangedFile) -> Void

    var body: some View {
        Group {
            if let preview {
                switch preview.content {
                case .unifiedDiff:
                    ReviewPreviewContent(preview: preview)
                default:
                    VStack(spacing: 0) {
                        DiffFileHeader(file: file, summary: summary)
                        ReviewPreviewContent(preview: preview)
                            .frame(minHeight: 220)
                            .background(DiffPalette.background)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    DiffFileHeader(file: file, summary: summary)
                    VStack(spacing: L5Spacing.x3) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isLoading ? "Loading diff" : "Preparing diff")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(DiffPalette.mutedText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .background(DiffPalette.background)
                }
                .onAppear { loadPreviewAction(file) }
            }
        }
    }

    private var summary: String {
        "+\(file.additions) -\(file.deletions)"
    }
}

private struct DiffPreviewView: View {
    let diff: String
    let file: ProjectChangedFile
    @State private var rows: [DiffRow]?

    private var visibleRows: [DiffRow] {
        rows ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            DiffFileHeader(file: file, summary: summary)

            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows == nil {
                        HStack(spacing: L5Spacing.x3) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Rendering diff")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(DiffPalette.mutedText)
                        }
                        .frame(minWidth: 760, minHeight: 120)
                    } else {
                        ForEach(visibleRows) { row in
                            DiffRowView(row: row, path: file.path)
                        }
                    }
                }
                .padding(.vertical, L5Spacing.x1)
                .frame(minWidth: 760, alignment: .leading)
            }
        }
        .background(DiffPalette.background)
        .task(id: diff) {
            rows = nil
            let parsed = await Task.detached(priority: .userInitiated) {
                DiffRow.parse(diff)
            }.value
            guard !Task.isCancelled else { return }
            rows = parsed
        }
    }

    private var summary: String {
        if let rows {
            let additions = rows.filter { $0.kind == .addition }.count
            let deletions = rows.filter { $0.kind == .deletion }.count
            return "+\(additions) -\(deletions)"
        }
        return "+\(file.additions) -\(file.deletions)"
    }
}

private struct DiffFileHeader: View {
    let file: ProjectChangedFile
    let summary: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: fileIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DiffPalette.icon)
                .frame(width: 32)

            HStack(spacing: 0) {
                Text(parentPath)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DiffPalette.pathText)
                    .lineLimit(1)

                Text(fileName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DiffPalette.primaryText)
                    .lineLimit(1)

                if let markerText {
                    Text(markerText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(DiffPalette.mutedText)
                        .padding(.horizontal, L5Spacing.x2)
                        .padding(.vertical, 3)
                        .background(DiffPalette.pill, in: Capsule())
                        .padding(.leading, L5Spacing.x2)
                }
            }

            Spacer(minLength: L5Spacing.x4)

            Text(summary)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(summary.hasPrefix("+0 -0") ? DiffPalette.mutedText : DiffPalette.addedLineNumber)

            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(width: 32)
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(width: 32)
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(width: 32)
        }
        .padding(.leading, L5Spacing.x3)
        .padding(.trailing, L5Spacing.x3)
        .frame(height: 46)
        .background(DiffPalette.fileHeader)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DiffPalette.separator)
                .frame(height: 1)
        }
        .overlay(alignment: .bottomLeading) {
            if let oldPath = file.oldPath {
                Text("Renamed from \(oldPath)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DiffPalette.mutedText)
                    .lineLimit(1)
                    .padding(.leading, 44)
                    .offset(y: 15)
            }
        }
    }

    private var fileName: String {
        URL(fileURLWithPath: file.path).lastPathComponent
    }

    private var parentPath: String {
        let url = URL(fileURLWithPath: file.path)
        let parent = url.deletingLastPathComponent().path
        let trimmed = parent.hasPrefix("/") ? String(parent.dropFirst()) : parent
        return trimmed.isEmpty ? "" : "\(trimmed)/"
    }

    private var markerText: String? {
        switch file.contentKind {
        case .image:
            "Image"
        case .binary:
            "Binary"
        case .submodule:
            "Submodule"
        case .symlink:
            "Symlink"
        case .unknown:
            "Unknown"
        case .text:
            nil
        }
    }

    private var fileIcon: String {
        switch file.contentKind {
        case .image:
            return "photo"
        case .binary:
            return "shippingbox"
        case .submodule:
            return "folder.badge.gearshape"
        case .symlink:
            return "link"
        case .text, .unknown:
            break
        }

        return switch URL(fileURLWithPath: file.path).pathExtension.lowercased() {
        case "swift":
            "swift"
        default:
            file.changeKind == .deleted ? "doc.badge.minus" : "doc.text"
        }
    }
}

private struct DiffRowView: View {
    let row: DiffRow
    let path: String

    var body: some View {
        switch row.kind {
        case let .fold(count):
            FoldRow(count: count)
        case .header:
            metadataRow
        case .hunk:
            hunkRow
        case .addition, .deletion, .context:
            codeRow
        }
    }

    private var codeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            LineNumberColumn(value: row.oldLine, color: row.lineNumberColor)
            LineNumberColumn(value: row.newLine, color: row.lineNumberColor)

            Text(row.displayText)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(row.textColor)
                .lineLimit(1)
                .frame(minWidth: 660, minHeight: 28, alignment: .leading)
                .padding(.leading, L5Spacing.x4)
                .padding(.trailing, L5Spacing.x4)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(row.edgeColor)
                .frame(width: 4)
        }
        .background(row.background)
    }

    private var metadataRow: some View {
        HStack(spacing: 0) {
            Text(row.text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(minWidth: 760, minHeight: 24, alignment: .leading)
                .padding(.leading, 108)
        }
        .background(DiffPalette.background)
    }

    private var hunkRow: some View {
        HStack(spacing: 0) {
            Text(row.text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DiffPalette.hunkText)
                .frame(minWidth: 760, minHeight: 26, alignment: .leading)
                .padding(.leading, 108)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DiffPalette.accent.opacity(0.7))
                .frame(width: 4)
        }
        .background(DiffPalette.hunkBackground)
    }
}

private struct LineNumberColumn: View {
    let value: Int?
    let color: Color

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 54, height: 28, alignment: .trailing)
            .padding(.trailing, L5Spacing.x3)
            .background(DiffPalette.gutter)
    }
}

private struct FoldRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(width: 104, height: 34)
                .background(DiffPalette.foldGutter)
            Text("\(count) unmodified \(count == 1 ? "line" : "lines")")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(minWidth: 656, minHeight: 34, alignment: .leading)
                .padding(.horizontal, L5Spacing.x3)
                .background(DiffPalette.foldBackground)
        }
    }
}
private struct ImagePreview: View {
    let path: String
    let byteSize: Int?

    var body: some View {
        VStack(spacing: L5Spacing.x4) {
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MetadataPreview(systemImage: "photo", title: "Image preview unavailable")
            }
            if let byteSize {
                Text("\(byteSize.formatted()) bytes")
                    .font(L5Font.caption)
                    .foregroundStyle(L5Color.textMuted)
            }
        }
        .padding(L5Spacing.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MetadataPreview: View {
    let systemImage: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: L5Spacing.x3) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
            Text(title)
                .font(L5Font.body.weight(.semibold))
                .multilineTextAlignment(.center)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(L5Font.caption)
                    .foregroundStyle(L5Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(L5Color.textPrimary)
        .padding(L5Spacing.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffRow: Identifiable, Sendable {
    let id: Int
    let text: String
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?

    enum Kind: Equatable, Sendable {
        case header
        case hunk
        case addition
        case deletion
        case context
        case fold(Int)
    }

    var background: Color {
        switch kind {
        case .addition:
            DiffPalette.addedBackground
        case .deletion:
            DiffPalette.deletedBackground
        case .hunk:
            DiffPalette.hunkBackground
        case .header:
            DiffPalette.background
        case .fold:
            DiffPalette.foldBackground
        case .context:
            DiffPalette.background
        }
    }

    var edgeColor: Color {
        switch kind {
        case .addition:
            DiffPalette.addedEdge
        case .deletion:
            DiffPalette.deletedEdge
        default:
            .clear
        }
    }

    var textColor: Color {
        switch kind {
        case .addition:
            DiffPalette.addedText
        case .deletion:
            DiffPalette.deletedText
        default:
            DiffPalette.primaryText
        }
    }

    var lineNumberColor: Color {
        switch kind {
        case .addition:
            DiffPalette.addedLineNumber
        case .deletion:
            DiffPalette.deletedLineNumber
        default:
            DiffPalette.lineNumber
        }
    }

    var displayText: String {
        if text.hasPrefix("+") || text.hasPrefix("-") || text.hasPrefix(" ") {
            return String(text.dropFirst())
        }
        return text
    }

    static func parse(_ diff: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldLine: Int?
        var newLine: Int?
        var oldCursor = 1

        func append(_ text: String, kind: Kind, old: Int?, new: Int?) {
            rows.append(DiffRow(id: rows.count, text: text, kind: kind, oldLine: old, newLine: new))
        }

        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
                let range = parseHunk(line)
                if let start = range.oldStart, start > oldCursor {
                    append("", kind: .fold(start - oldCursor), old: nil, new: nil)
                }
                oldLine = range.old
                newLine = range.new
                if let oldStart = range.oldStart, let oldCount = range.oldCount {
                    oldCursor = oldStart + max(oldCount, 1)
                }
                append(line, kind: .hunk, old: nil, new: nil)
                continue
            }
            if line.hasPrefix("diff --git") || line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("index ") {
                append(line, kind: .header, old: nil, new: nil)
                continue
            }
            if line.hasPrefix("+") {
                append(line, kind: .addition, old: nil, new: newLine)
                newLine = newLine.map { $0 + 1 }
                continue
            }
            if line.hasPrefix("-") {
                append(line, kind: .deletion, old: oldLine, new: nil)
                oldLine = oldLine.map { $0 + 1 }
                continue
            }
            append(line, kind: .context, old: oldLine, new: newLine)
            oldLine = oldLine.map { $0 + 1 }
            newLine = newLine.map { $0 + 1 }
        }
        return rows
    }

    private static func parseHunk(_ line: String) -> (old: Int?, new: Int?, oldStart: Int?, oldCount: Int?) {
        let parts = line.split(separator: " ")
        let oldParts = parts.first { $0.hasPrefix("-") }?.dropFirst().split(separator: ",")
        let old = oldParts?.first.flatMap { Int($0) }
        let oldCount = oldParts?.dropFirst().first.flatMap { Int($0) } ?? 1
        let new = parts.first { $0.hasPrefix("+") }?.dropFirst().split(separator: ",").first.flatMap { Int($0) }
        return (old, new, old, oldCount)
    }
}

private enum DiffPalette {
    static let background = Color(red: 0.075, green: 0.078, blue: 0.082)
    static let header = Color(red: 0.105, green: 0.108, blue: 0.112)
    static let fileHeader = Color(red: 0.120, green: 0.123, blue: 0.128)
    static let toolbarButton = Color.white.opacity(0.050)
    static let pill = Color.white.opacity(0.070)
    static let gutter = Color(red: 0.070, green: 0.073, blue: 0.077)
    static let foldGutter = Color(red: 0.095, green: 0.098, blue: 0.104)
    static let foldBackground = Color(red: 0.110, green: 0.113, blue: 0.120)
    static let hunkBackground = Color(red: 0.095, green: 0.113, blue: 0.135)
    static let addedBackground = Color(red: 0.075, green: 0.155, blue: 0.095)
    static let deletedBackground = Color(red: 0.170, green: 0.080, blue: 0.080)
    static let addedEdge = Color(red: 0.330, green: 0.880, blue: 0.520)
    static let deletedEdge = Color(red: 0.940, green: 0.320, blue: 0.320)
    static let separator = Color.white.opacity(0.055)
    static let primaryText = Color(red: 0.905, green: 0.910, blue: 0.920)
    static let pathText = Color(red: 0.520, green: 0.535, blue: 0.560)
    static let mutedText = Color(red: 0.550, green: 0.565, blue: 0.590)
    static let lineNumber = Color(red: 0.565, green: 0.580, blue: 0.605)
    static let addedLineNumber = Color(red: 0.440, green: 0.900, blue: 0.600)
    static let deletedLineNumber = Color(red: 0.980, green: 0.400, blue: 0.400)
    static let addedText = Color(red: 0.620, green: 0.970, blue: 0.730)
    static let deletedText = Color(red: 1.000, green: 0.580, blue: 0.580)
    static let hunkText = Color(red: 0.520, green: 0.720, blue: 0.980)
    static let icon = Color(red: 0.950, green: 0.530, blue: 0.230)
    static let accent = Color(red: 0.370, green: 0.610, blue: 0.950)
}
