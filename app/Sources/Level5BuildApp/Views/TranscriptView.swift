import AppKit
import Level5Design
import SwiftUI
import SwiftUIIntrospect

struct TranscriptView: View {
    let items: [AgentTranscriptItem]
    let scrollIdentity: String?
    let followsTail: Bool
    let setFollowsTail: (Bool) -> Void

    @StateObject private var scrollController = TranscriptScrollController()

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
            .padding(.top, L5Spacing.x6)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .introspect(.scrollView, on: .macOS(.v14, .v15, .v26)) { scrollView in
            scrollController.attach(scrollView)
            scrollController.update(followsTail: followsTail, setFollowsTail: setFollowsTail)
        }
        .onAppear {
            scrollController.update(followsTail: followsTail, setFollowsTail: setFollowsTail)
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
            return
        }

        if isUserScrollEvent {
            cancelSettle()
            reportBottomState()
            return
        }

        if isSettling {
            return
        }

        if sizeChanged, followsTail {
            settleToBottom(reason: .content)
        } else if originChanged || sizeChanged {
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

    var body: some View {
        HStack(alignment: .top, spacing: L5Spacing.x3) {
            roleIcon
                .frame(width: 26, height: 26)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: L5Spacing.x1) {
                Text(roleTitle)
                    .font(L5Font.caption)
                    .foregroundStyle(.secondary)

                Text(item.renderText)
                    .font(L5Font.body)
                    .foregroundStyle(L5Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder
    private var roleIcon: some View {
        switch item.role {
        case .user:
            Image(systemName: "person.fill")
                .foregroundStyle(.white)
        case .agent:
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
        case .plan:
            Image(systemName: "list.bullet.clipboard")
                .foregroundStyle(.secondary)
        case .tool:
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.secondary)
        case .usage:
            Image(systemName: "gauge")
                .foregroundStyle(.secondary)
        case .status:
            Image(systemName: "info")
                .foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
        }
    }

    private var roleTitle: String {
        switch item.role {
        case .user: "You"
        case .agent: "Agent"
        case .plan: item.renderStatus.map { "Plan - \($0)" } ?? "Plan"
        case .tool: item.renderStatus.map { "Tool - \($0)" } ?? "Tool"
        case .usage: "Usage"
        case .status: "Status"
        case .error: "Error"
        }
    }

    private var iconBackground: Color {
        switch item.role {
        case .user: L5Color.accent
        case .agent: Color(nsColor: .systemGreen)
        case .plan: Color(nsColor: .systemBlue).opacity(0.12)
        case .tool: Color(nsColor: .systemOrange).opacity(0.14)
        case .usage: Color(nsColor: .systemPurple).opacity(0.14)
        case .status: L5Color.secondaryBackground
        case .error: Color(nsColor: .systemRed)
        }
    }

    private var rowMaterial: Material {
        switch item.role {
        case .user: .regularMaterial
        case .agent: .regularMaterial
        case .plan, .tool, .usage, .status, .error: .thinMaterial
        }
    }
}

private enum TranscriptRenderRole {
    case user
    case agent
    case plan
    case tool
    case usage
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
        case .plan: .plan
        case .tool: .tool
        case .usage: .usage
        case .status: .status
        case .error: .error
        }
    }

    var renderText: String {
        switch kind {
        case let .message(message):
            let suffix = message.unsupportedBlockCount > 0 ? "\n[\(message.unsupportedBlockCount) unsupported block\(message.unsupportedBlockCount == 1 ? "" : "s")]" : ""
            return message.text + suffix
        case let .plan(plan):
            return plan.text
        case let .tool(tool):
            return tool.text ?? tool.title
        case let .usage(usage):
            return usage.text
        case let .status(status):
            return status.text
        case let .error(error):
            return error.text
        }
    }

    var renderStatus: String? {
        switch kind {
        case let .plan(plan):
            return plan.status
        case let .tool(tool):
            return tool.status ?? tool.kind
        default:
            return nil
        }
    }
}
