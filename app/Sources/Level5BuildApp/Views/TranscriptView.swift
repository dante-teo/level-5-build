import AppKit
import Level5Design
import SwiftUI
import SwiftUIIntrospect

struct TranscriptView: View {
    let items: [AgentTranscriptItem]
    let scrollIdentity: String?
    var topContentInset: CGFloat = L5Spacing.x6
    let followsTail: Bool
    let setFollowsTail: (Bool) -> Void

    @StateObject private var scrollController = TranscriptScrollController()
    @State private var scrollProgress: CGFloat = 1

    private let bottomInset: CGFloat = L5Spacing.x6

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: L5Spacing.x4) {
                ForEach(items) { item in
                    TranscriptRow(item: item)
                }

                Color.clear
                    .frame(height: bottomInset)
            }
            .padding(.horizontal, L5Spacing.x6)
            .padding(.top, topContentInset)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .leading) {
            TranscriptScrollRail(progress: scrollProgress)
                .padding(.leading, L5Spacing.x4)
                .allowsHitTesting(false)
        }
        .scrollContentBackground(.hidden)
        .introspect(.scrollView, on: .macOS(.v14, .v15, .v26)) { scrollView in
            scrollController.attach(scrollView)
            scrollController.update(followsTail: followsTail, setFollowsTail: setFollowsTail)
            scrollController.update(setScrollProgress: { scrollProgress = $0 })
        }
        .onAppear {
            scrollController.update(followsTail: followsTail, setFollowsTail: setFollowsTail)
            scrollController.update(setScrollProgress: { scrollProgress = $0 })
            scrollController.viewAppeared()
        }
        .onChange(of: scrollIdentity) { _, _ in
            scrollController.update(followsTail: followsTail, setFollowsTail: setFollowsTail)
            scrollController.scrollIdentityChanged()
        }
        .onChange(of: transcriptVersion) { _, _ in
            scrollController.update(followsTail: followsTail, setFollowsTail: setFollowsTail)
            scrollController.contentChanged()
        }
        .onChange(of: followsTail) { _, newValue in
            scrollController.update(followsTail: newValue, setFollowsTail: setFollowsTail)
            scrollController.externalFollowsTailChanged(newValue)
        }
        .onDisappear {
            scrollController.viewDisappeared()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var transcriptVersion: String {
        items
            .map { "\($0.id):\($0.renderText.count)" }
            .joined(separator: "|")
    }
}

private struct TranscriptScrollRail: View {
    let progress: CGFloat

    var body: some View {
        let activeIndex = L5TranscriptScrollRail.activeIndex(progress: progress)

        VStack(spacing: L5TranscriptScrollRail.markerSpacing) {
            ForEach(0..<L5TranscriptScrollRail.markerCount, id: \.self) { index in
                Capsule()
                    .fill(index == activeIndex ? L5Color.textPrimary : L5Color.textMuted.opacity(L5TranscriptScrollRail.inactiveOpacity))
                    .frame(width: L5TranscriptScrollRail.markerWidth, height: L5TranscriptScrollRail.markerHeight)
            }
        }
        .frame(width: L5TranscriptScrollRail.railWidth)
    }
}

@MainActor
final class TranscriptScrollController: NSObject, ObservableObject {
    private enum SettleReason {
        case initial
        case content
    }

    private let bottomThreshold: CGFloat = L5Spacing.x6
    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var settleTask: Task<Void, Never>?
    private var followsTail = true
    private var setFollowsTail: ((Bool) -> Void)?
    private var setScrollProgress: ((CGFloat) -> Void)?
    private var isProgrammaticScroll = false
    private var isSettling = false
    private var lastClipBounds: CGRect = .zero
    private var lastDocumentHeight: CGFloat = 0

    deinit {
        settleTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func attach(_ scrollView: NSScrollView) {
        if self.scrollView !== scrollView {
            removeObservers()
            self.scrollView = scrollView
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            lastClipBounds = scrollView.contentView.bounds
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChangeNotification(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
            )
        }

        observeDocumentViewIfNeeded()
    }

    func update(followsTail: Bool, setFollowsTail: @escaping (Bool) -> Void) {
        self.followsTail = followsTail
        self.setFollowsTail = setFollowsTail
    }

    func update(setScrollProgress: @escaping (CGFloat) -> Void) {
        self.setScrollProgress = setScrollProgress
        reportScrollProgress()
    }

    func viewAppeared() {
        observeDocumentViewIfNeeded()
        if followsTail {
            settleToBottom(reason: .initial)
        } else {
            reportBottomState()
        }
    }

    func viewDisappeared() {
        cancelSettle()
    }

    func scrollIdentityChanged() {
        observeDocumentViewIfNeeded()
        if followsTail {
            settleToBottom(reason: .initial)
        } else {
            reportBottomState()
        }
    }

    func contentChanged() {
        observeDocumentViewIfNeeded()
        if followsTail {
            settleToBottom(reason: .content)
        } else {
            reportBottomState()
        }
    }

    func externalFollowsTailChanged(_ followsTail: Bool) {
        self.followsTail = followsTail
        if followsTail {
            settleToBottom(reason: .content)
        } else {
            cancelSettle()
        }
    }

    private func observeDocumentViewIfNeeded() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        guard self.documentView !== documentView else { return }

        if let existingDocumentView = self.documentView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: existingDocumentView
            )
        }

        self.documentView = documentView
        documentView.postsFrameChangedNotifications = true
        lastDocumentHeight = documentView.bounds.height
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentFrameDidChangeNotification(_:)),
            name: NSView.frameDidChangeNotification,
            object: documentView
        )
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        documentView = nil
    }

    @objc private func clipBoundsDidChangeNotification(_ notification: Notification) {
        clipBoundsDidChange()
    }

    @objc private func documentFrameDidChangeNotification(_ notification: Notification) {
        documentFrameDidChange()
    }

    private func clipBoundsDidChange() {
        guard let scrollView else { return }

        let clipBounds = scrollView.contentView.bounds
        let originChanged = abs(clipBounds.origin.y - lastClipBounds.origin.y) > 0.5
        let sizeChanged = abs(clipBounds.size.width - lastClipBounds.size.width) > 0.5
            || abs(clipBounds.size.height - lastClipBounds.size.height) > 0.5
        lastClipBounds = clipBounds

        if isProgrammaticScroll {
            reportScrollProgress()
            return
        }

        if isUserScrollEvent {
            cancelSettle()
            reportScrollProgress()
            reportBottomState()
            return
        }

        if isSettling {
            return
        }

        if sizeChanged, followsTail {
            settleToBottom(reason: .content)
        } else if originChanged || sizeChanged {
            reportScrollProgress()
            reportBottomState()
        }
    }

    private func documentFrameDidChange() {
        observeDocumentViewIfNeeded()
        guard let documentView else { return }

        let documentHeight = documentView.bounds.height
        let heightChanged = abs(documentHeight - lastDocumentHeight) > 0.5
        lastDocumentHeight = documentHeight
        guard heightChanged else { return }

        if followsTail {
            settleToBottom(reason: .content)
        } else if !isSettling {
            reportScrollProgress()
            reportBottomState()
        }
    }

    private func settleToBottom(reason: SettleReason) {
        settleTask?.cancel()
        isSettling = true
        scrollToBottom()

        let delays: [UInt64] = switch reason {
        case .initial:
            [16_000_000, 50_000_000, 120_000_000, 260_000_000, 520_000_000]
        case .content:
            [16_000_000, 80_000_000, 180_000_000]
        }

        settleTask = Task { @MainActor [weak self] in
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                guard self.followsTail else {
                    self.cancelSettle()
                    return
                }
                self.scrollToBottom()
            }

            guard !Task.isCancelled, let self else { return }
            self.isSettling = false
            self.reportBottomState()
        }
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        isSettling = false
    }

    private func scrollToBottom() {
        guard let scrollView else { return }
        observeDocumentViewIfNeeded()
        guard let documentView else { return }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let targetY = TranscriptScrollMetrics.bottomOriginY(
            documentBounds: documentView.bounds,
            viewportHeight: clipView.bounds.height,
            isFlipped: documentView.isFlipped
        )
        isProgrammaticScroll = true
        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        lastClipBounds = clipView.bounds
        isProgrammaticScroll = false
        reportScrollProgress()
    }

    private func reportBottomState() {
        guard let scrollView else { return }
        observeDocumentViewIfNeeded()
        guard let documentView else { return }

        let isAtBottom = TranscriptScrollMetrics.isAtBottom(
            documentBounds: documentView.bounds,
            visibleRect: documentView.visibleRect,
            viewportHeight: scrollView.contentView.bounds.height,
            isFlipped: documentView.isFlipped,
            threshold: bottomThreshold
        )
        guard isAtBottom != followsTail else { return }
        followsTail = isAtBottom
        if !isAtBottom {
            cancelSettle()
        }
        setFollowsTail?(isAtBottom)
    }

    private func reportScrollProgress() {
        guard let scrollView else { return }
        observeDocumentViewIfNeeded()
        guard let documentView else { return }

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.bounds.height
        let scrollableHeight = documentHeight - viewportHeight
        guard scrollableHeight > 0 else {
            setScrollProgress?(1)
            return
        }

        let visibleRect = documentView.visibleRect
        let rawProgress: CGFloat
        if documentView.isFlipped {
            rawProgress = visibleRect.minY / scrollableHeight
        } else {
            rawProgress = (documentHeight - visibleRect.maxY) / scrollableHeight
        }

        setScrollProgress?(min(max(rawProgress, 0), 1))
    }

    private var isUserScrollEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .scrollWheel,
             .swipe,
             .magnify,
             .beginGesture,
             .endGesture,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
             .keyDown:
            return true
        default:
            return false
        }
    }
}

private enum L5TranscriptScrollRail {
    static let railWidth = L5Spacing.x3
    static let markerWidth = L5Spacing.x3
    static let markerHeight = L5Spacing.x1
    static let markerSpacing = L5Spacing.x3
    static let markerCount = 12
    static let inactiveOpacity = L5Spacing.x2 / L5Spacing.x10

    static func activeIndex(progress: CGFloat) -> Int {
        guard markerCount > 1 else { return 0 }
        let clampedProgress = min(max(progress, 0), 1)
        return min(markerCount - 1, max(0, Int((clampedProgress * CGFloat(markerCount - 1)).rounded())))
    }
}

enum TranscriptScrollMetrics {
    static func bottomOriginY(documentBounds: CGRect, viewportHeight: CGFloat, isFlipped: Bool) -> CGFloat {
        guard documentBounds.height > viewportHeight else {
            return documentBounds.minY
        }

        if isFlipped {
            return max(documentBounds.maxY - viewportHeight, documentBounds.minY)
        }

        return documentBounds.minY
    }

    static func isAtBottom(
        documentBounds: CGRect,
        visibleRect: CGRect,
        viewportHeight: CGFloat,
        isFlipped: Bool,
        threshold: CGFloat
    ) -> Bool {
        guard documentBounds.height > viewportHeight + threshold else {
            return true
        }

        let bottomGap = if isFlipped {
            documentBounds.maxY - visibleRect.maxY
        } else {
            visibleRect.minY - documentBounds.minY
        }

        return bottomGap <= threshold
    }
}

private struct TranscriptRow: View {
    let item: AgentTranscriptItem
    @State private var isManuallyExpanded: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: L5Spacing.x3) {
            roleIcon
                .frame(width: 26, height: 26)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: L5Spacing.x1) {
                Text(roleTitle)
                    .font(L5Font.caption)
                    .foregroundStyle(.secondary)

                if case let .tool(tool) = item.kind {
                    ToolDisclosureContent(
                        tool: tool,
                        isExpanded: effectiveToolExpansion(tool),
                        toggle: {
                            guard AgentTranscriptStatusNormalizer.normalized(tool.status) != "failed" else { return }
                            isManuallyExpanded = !effectiveToolExpansion(tool)
                        }
                    )
                    .textSelection(.enabled)
                    .onChange(of: tool.isExpanded) { _, newValue in
                        if isManuallyExpanded == nil {
                            isManuallyExpanded = newValue
                        }
                    }
                } else {
                    Text(item.renderText)
                        .font(L5Font.body)
                        .foregroundStyle(L5Color.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(L5Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowMaterial, in: RoundedRectangle(cornerRadius: L5Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: L5Radius.small, style: .continuous)
                    .stroke(L5Color.border, lineWidth: 1)
            }
        }
    }

    private func effectiveToolExpansion(_ tool: AgentTranscriptTool) -> Bool {
        if AgentTranscriptStatusNormalizer.normalized(tool.status) == "failed" {
            return true
        }
        return isManuallyExpanded ?? tool.isExpanded
    }

    @ViewBuilder
    private var roleIcon: some View {
        switch item.role {
        case .user:
            L5IconView(.user)
                .foregroundStyle(.white)
        case .agent:
            L5IconView(.agent)
                .foregroundStyle(.white)
        case .tool:
            L5IconView(.tool)
                .foregroundStyle(.secondary)
        case .status:
            L5IconView(.status)
                .foregroundStyle(.secondary)
        case .error:
            L5IconView(.error)
                .foregroundStyle(.white)
        }
    }

    private var roleTitle: String {
        switch item.role {
        case .user: "You"
        case .agent: "Agent"
        case .tool: item.renderStatus.map { "Tool - \($0)" } ?? "Tool"
        case .status: "Status"
        case .error: "Error"
        }
    }

    private var iconBackground: Color {
        switch item.role {
        case .user: L5Color.accent
        case .agent: Color(nsColor: .systemGreen)
        case .tool: Color(nsColor: .systemOrange).opacity(0.14)
        case .status: L5Color.secondaryBackground
        case .error: Color(nsColor: .systemRed)
        }
    }

    private var rowMaterial: Material {
        switch item.role {
        case .user: .regularMaterial
        case .agent: .regularMaterial
        case .tool, .status, .error: .thinMaterial
        }
    }
}

private struct ToolDisclosureContent: View {
    let tool: AgentTranscriptTool
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x2) {
            Button(action: toggle) {
                HStack(spacing: L5Spacing.x2) {
                    Text(tool.title)
                        .font(L5Font.body)
                        .foregroundStyle(L5Color.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: L5Spacing.x1) {
                    if let status = AgentTranscriptStatusNormalizer.display(tool.status) {
                        ToolDetailLine(label: "Status", value: status)
                    }
                    if let kind = tool.kind?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                        ToolDetailLine(label: "Kind", value: AgentTranscriptStatusNormalizer.display(kind) ?? kind)
                    }
                    if let text = tool.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                        Text(text)
                            .font(L5Font.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, L5Spacing.x1)
                    }
                }
                .padding(.top, L5Spacing.x1)
            } else if let text = tool.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                Text(text)
                    .font(L5Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ToolDetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: L5Spacing.x2) {
            Text(label)
                .font(L5Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)

            Text(value)
                .font(L5Font.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private enum TranscriptRenderRole {
    case user
    case agent
    case tool
    case status
    case error
}

private extension AgentTranscriptItem {
    var role: TranscriptRenderRole {
        switch kind {
        case let .message(message):
            switch message.role {
            case .user: .user
            case .agent: .agent
            }
        case .tool: .tool
        case .status: .status
        case .error: .error
        }
    }

    var renderText: String {
        switch kind {
        case let .message(message):
            let suffix = message.unsupportedBlockCount > 0 ? "\n[\(message.unsupportedBlockCount) unsupported block\(message.unsupportedBlockCount == 1 ? "" : "s")]" : ""
            return message.text + suffix
        case let .tool(tool):
            return tool.summaryText
        case let .status(status):
            return status.text
        case let .error(error):
            return error.text
        }
    }

    var renderStatus: String? {
        switch kind {
        case let .tool(tool):
            return AgentTranscriptStatusNormalizer.display(tool.status ?? tool.kind)
        default:
            return nil
        }
    }
}

private extension AgentTranscriptTool {
    var summaryText: String {
        let pieces = [
            kind.map { AgentTranscriptStatusNormalizer.display($0) ?? $0 },
            text
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        guard !pieces.isEmpty else { return title }
        return pieces.joined(separator: " - ")
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
