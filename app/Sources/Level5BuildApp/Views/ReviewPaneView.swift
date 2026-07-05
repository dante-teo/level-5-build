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
        VStack(alignment: .leading, spacing: L5Spacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: L5Spacing.x3) {
                VStack(alignment: .leading, spacing: L5Spacing.x1) {
                    HStack(spacing: L5Spacing.x2) {
                        Text("Review")
                            .font(L5Font.h3)
                            .foregroundStyle(DiffPalette.primaryText)

                        Text(countText)
                            .font(L5Font.caption.weight(.semibold))
                            .foregroundStyle(L5Color.accent)
                            .padding(.horizontal, L5Spacing.x2)
                            .frame(height: L5Size.action)
                            .background(DiffPalette.pill, in: Capsule())

                        Text(additionsText)
                            .font(L5Font.caption.weight(.semibold))
                            .foregroundStyle(DiffPalette.addedLineNumber)

                        Text(deletionsText)
                            .font(L5Font.caption.weight(.semibold))
                            .foregroundStyle(DiffPalette.deletedLineNumber)
                    }

                    if let rootHint {
                        Label(rootHint, systemImage: "folder")
                            .font(L5Font.caption)
                            .foregroundStyle(DiffPalette.mutedText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: L5Spacing.x3)

                HStack(spacing: L5Spacing.x2) {
                    if state.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                    }

                    Button(action: refreshAction) {
                        L5IconView(.refresh)
                            .frame(width: L5Size.hitTarget, height: L5Size.hitTarget)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh Review")

                    ReviewPaneToggleButton(
                        isSelected: true,
                        action: closeAction
                    )
                }
            }

            HStack(spacing: L5Spacing.x2) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(DiffPalette.mutedText)
                TextField("Filter changed files", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(L5Font.caption)
                    .foregroundStyle(DiffPalette.primaryText)

                if isAgentRunning {
                    Divider()
                        .frame(height: L5Size.icon)
                    Label("Refresh after turn", systemImage: "clock")
                        .lineLimit(1)
                }
            }
            .font(L5Font.caption)
            .foregroundStyle(DiffPalette.mutedText)
            .padding(.horizontal, L5Spacing.x3)
            .frame(height: L5Size.control)
            .background(DiffPalette.field, in: RoundedRectangle(cornerRadius: L5Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: L5Radius.medium, style: .continuous)
                    .stroke(DiffPalette.separator, lineWidth: 1)
            }
        }
        .padding(L5Spacing.x4)
        .background(DiffPalette.header)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DiffPalette.separator)
                .frame(height: 1)
        }
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
                            .font(L5Font.caption.weight(.semibold))
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
                                .font(L5Font.caption.weight(.semibold))
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
                .frame(width: L5Size.control)

            HStack(spacing: 0) {
                Text(parentPath)
                    .font(L5Font.body.weight(.semibold))
                    .foregroundStyle(DiffPalette.pathText)
                    .lineLimit(1)

                Text(fileName)
                    .font(L5Font.body.weight(.bold))
                    .foregroundStyle(DiffPalette.primaryText)
                    .lineLimit(1)

                if let markerText {
                    Text(markerText)
                        .font(L5Font.caption.weight(.semibold))
                        .foregroundStyle(DiffPalette.mutedText)
                        .padding(.horizontal, L5Spacing.x2)
                        .padding(.vertical, L5Spacing.x1)
                        .background(DiffPalette.pill, in: Capsule())
                        .padding(.leading, L5Spacing.x2)
                }
            }

            Spacer(minLength: L5Spacing.x4)

            Text(summary)
                .font(L5Font.body.weight(.semibold))
                .foregroundStyle(summary.hasPrefix("+0 -0") ? DiffPalette.mutedText : DiffPalette.addedLineNumber)
        }
        .padding(.leading, L5Spacing.x3)
        .padding(.trailing, L5Spacing.x3)
        .frame(height: L5Spacing.x12)
        .background(DiffPalette.fileHeader)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DiffPalette.separator)
                .frame(height: 1)
        }
        .overlay(alignment: .bottomLeading) {
            if let oldPath = file.oldPath {
                Text("Renamed from \(oldPath)")
                    .font(L5Font.caption)
                    .foregroundStyle(DiffPalette.mutedText)
                    .lineLimit(1)
                    .padding(.leading, L5Size.control + L5Spacing.x3)
                    .offset(y: L5Spacing.x4)
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

    private enum Metrics {
        static let gutterWidth: CGFloat = 54
        static let gutterPairWidth: CGFloat = gutterWidth * 2
        static let rowHeight: CGFloat = 28
        static let metadataRowHeight: CGFloat = 24
        static let hunkRowHeight: CGFloat = 26
        static let edgeWidth: CGFloat = 4
        static let minTextWidth: CGFloat = 660
        static let minDocumentWidth: CGFloat = gutterPairWidth + minTextWidth
    }

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
                .font(L5Font.mono(size: 14).weight(.medium))
                .foregroundStyle(row.textColor)
                .lineLimit(1)
                .frame(minWidth: Metrics.minTextWidth, minHeight: Metrics.rowHeight, alignment: .leading)
                .padding(.leading, L5Spacing.x4)
                .padding(.trailing, L5Spacing.x4)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(row.edgeColor)
                .frame(width: Metrics.edgeWidth)
        }
        .background(row.background)
    }

    private var metadataRow: some View {
        HStack(spacing: 0) {
            Text(row.text)
                .font(L5Font.mono(size: 12).weight(.medium))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(minWidth: Metrics.minDocumentWidth, minHeight: Metrics.metadataRowHeight, alignment: .leading)
                .padding(.leading, Metrics.gutterPairWidth)
        }
        .background(DiffPalette.background)
    }

    private var hunkRow: some View {
        HStack(spacing: 0) {
            Text(row.text)
                .font(L5Font.mono(size: 12).weight(.semibold))
                .foregroundStyle(DiffPalette.hunkText)
                .frame(minWidth: Metrics.minDocumentWidth, minHeight: Metrics.hunkRowHeight, alignment: .leading)
                .padding(.leading, Metrics.gutterPairWidth)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DiffPalette.accent.opacity(0.7))
                .frame(width: Metrics.edgeWidth)
        }
        .background(DiffPalette.hunkBackground)
    }
}

private struct LineNumberColumn: View {
    let value: Int?
    let color: Color

    private enum Metrics {
        static let width: CGFloat = 54
        static let rowHeight: CGFloat = 28
    }

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(L5Font.mono(size: 14).weight(.medium))
            .foregroundStyle(color)
            .frame(width: Metrics.width, height: Metrics.rowHeight, alignment: .trailing)
            .padding(.trailing, L5Spacing.x3)
            .background(DiffPalette.gutter)
    }
}

private struct FoldRow: View {
    let count: Int

    private enum Metrics {
        static let gutterWidth: CGFloat = 108
        static let textWidth: CGFloat = 656
        static let rowHeight: CGFloat = 34
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(width: Metrics.gutterWidth, height: Metrics.rowHeight)
                .background(DiffPalette.foldGutter)
            Text("\(count) unmodified \(count == 1 ? "line" : "lines")")
                .font(L5Font.body.weight(.semibold))
                .foregroundStyle(DiffPalette.mutedText)
                .frame(minWidth: Metrics.textWidth, minHeight: Metrics.rowHeight, alignment: .leading)
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
    static let background = L5Color.background
    static let header = L5Color.elevatedSurface
    static let fileHeader = L5Color.secondaryBackground.opacity(0.74)
    static let field = L5Color.surface
    static let pill = L5Color.selectedSurface
    static let gutter = L5Color.secondaryBackground.opacity(0.72)
    static let foldGutter = L5Color.selectedSurface.opacity(0.54)
    static let foldBackground = L5Color.selectedSurface.opacity(0.34)
    static let hunkBackground = L5Color.accent.opacity(0.11)
    static let addedBackground = L5Color.success.opacity(0.13)
    static let deletedBackground = L5Color.danger.opacity(0.13)
    static let addedEdge = L5Color.success
    static let deletedEdge = L5Color.danger
    static let separator = L5Color.border
    static let primaryText = L5Color.textPrimary
    static let pathText = L5Color.textSecondary
    static let mutedText = L5Color.textMuted
    static let lineNumber = L5Color.textMuted
    static let addedLineNumber = L5Color.success
    static let deletedLineNumber = L5Color.danger
    static let addedText = L5Color.success
    static let deletedText = L5Color.danger
    static let hunkText = L5Color.accent
    static let icon = L5Color.accent
    static let accent = L5Color.accent
}
