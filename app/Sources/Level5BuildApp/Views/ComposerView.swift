import AppKit
import Level5Core
import Level5Design
import SwiftUI

struct ComposerView: View {
    let availability: AgentAvailability
    let runtimeMessage: String?
    let queuedPrompts: [QueuedPrompt]
    let plan: AgentPlanState?
    let usage: AgentTranscriptUsage?
    @Binding var draft: ComposerDraft
    let modelOptions: [ComposerModelOption]
    let slashCommands: [ComposerCommand]
    let approvalMode: ApprovalMode
    let pendingPermissionRequest: PermissionRequest?
    let isActiveSessionRunning: Bool
    let isModelSaveInFlight: Bool
    let isNewSession: Bool
    let selectedProject: RecentProject?
    let recentProjects: [RecentProject]
    let canSendWithButton: Bool
    let canEditComposer: Bool
    var isFocused: FocusState<Bool>.Binding
    let sendAction: () -> Void
    let cancelAction: () -> Void
    let selectModelAction: (String) -> Void
    let selectApprovalModeAction: (ApprovalMode) -> Void
    let respondToPermissionAction: (String) -> Void
    let rejectPermissionWithInstructionsAction: (String) -> Void
    let addAttachmentsAction: ([URL], ComposerAttachment.Kind) -> Void
    let removeAttachmentAction: (ComposerAttachment) -> Void
    let acceptSlashCommandAction: (ComposerCommand) -> Void
    let removeQueuedPromptAction: (QueuedPrompt) -> Void
    let selectProjectAction: (URL) -> Void
    let clearProjectAction: () -> Void
    let removeRecentProjectAction: (RecentProject) -> Void
    let validateProjectAction: (RecentProject) -> Bool
    @State private var highlightedCommandIndex = 0
    @State private var highlightedPermissionIndex = 0
    @State private var rejectionInstructions = ""
    @State private var editorHeight: CGFloat = L5Spacing.x6

    var body: some View {
        VStack(spacing: 0) {
            if let plan, !plan.entries.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    PlanChip(plan: plan, isRunning: isActiveSessionRunning)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, L5Spacing.x2)
            }

            if !queuedPrompts.isEmpty {
                PromptQueueView(
                    queuedPrompts: queuedPrompts,
                    removeAction: removeQueuedPromptAction
                )
                .padding(.bottom, L5Spacing.x2)
            }

            VStack(spacing: L5Spacing.x2) {
                if let statusMessage {
                    RuntimeStatusView(message: statusMessage)
                }

                if let pendingPermissionRequest {
                    PermissionTakeoverView(
                        request: pendingPermissionRequest,
                        highlightedIndex: $highlightedPermissionIndex,
                        instructionText: $rejectionInstructions,
                        respondAction: respondToPermissionAction,
                        rejectWithInstructionsAction: rejectPermissionWithInstructionsAction
                    )
                    .onChange(of: pendingPermissionRequest.id) { _, _ in
                        highlightedPermissionIndex = 0
                        rejectionInstructions = ""
                    }
                } else {
                    if !draft.attachments.isEmpty {
                        AttachmentChipsView(
                            chips: draft.attachmentChips(),
                            removeAction: removeAttachmentAction
                        )
                    }

                    ZStack(alignment: .topLeading) {
                        MultilineComposerTextView(
                            text: Binding(
                                get: { draft.plainText },
                                set: { draft.replacePlainTextPreservingCommandTokens($0) }
                            ),
                            isEditable: canEditComposer,
                            acceptAutocompleteAction: acceptHighlightedCommand,
                            heightChanged: { editorHeight = $0 },
                            submitAction: sendAction
                        )
                        .focused(isFocused)
                        .frame(minHeight: editorHeight, idealHeight: editorHeight, maxHeight: editorHeight)
                        .fixedSize(horizontal: false, vertical: true)

                        if draft.plainText.isEmpty {
                            Text("Do anything")
                                .font(L5Font.body)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                }

                HStack(spacing: L5Spacing.x2) {
                    AddMenu(
                        commands: slashCommands,
                        addAttachmentsAction: addAttachmentsAction,
                        acceptSlashCommandAction: acceptSlashCommandAction
                    )
                    .disabled(!canEditComposer)

                    ApprovalModeSelector(
                        selectedMode: approvalMode,
                        selectAction: selectApprovalModeAction
                    )
                    .disabled(pendingPermissionRequest != nil)

                    Spacer()

                    if let usage, usage.used ?? 0 > 0, let size = usage.size, size > 0 {
                        ContextUsageRing(usage: usage, size: size)
                    }

                    ModelSelector(
                        selectedModelId: Binding(
                            get: { draft.selectedModelId ?? modelOptions.first?.id },
                            set: { newValue in
                                if let newValue {
                                    selectModelAction(newValue)
                                }
                            }
                        ),
                        options: modelOptions,
                        isSaving: isModelSaveInFlight
                    )
                    .disabled(modelOptions.isEmpty || isModelSaveInFlight || !canEditComposer)

                    SendButton(
                        isEnabled: canSendWithButton,
                        isRunning: isActiveSessionRunning,
                        sendAction: sendAction,
                        cancelAction: cancelAction
                    )
                }
            }
            .padding(.horizontal, isNewSession ? L5Spacing.x4 : L5Spacing.x3)
            .padding(.top, isNewSession ? L5Spacing.x3 : L5Spacing.x3)
            .padding(.bottom, isNewSession ? L5Spacing.x3 : L5Spacing.x3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isNewSession ? L5Radius.card : L5Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: isNewSession ? L5Radius.card : L5Radius.medium, style: .continuous)
                    .stroke(L5Color.border.opacity(0.8), lineWidth: 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .shadow(
                color: .black.opacity(isNewSession ? 0.08 : 0),
                radius: isNewSession ? L5Spacing.x4 : 0,
                x: 0,
                y: isNewSession ? 10 : 0
            )

            if !filteredCommands.isEmpty {
                SlashCommandAutocomplete(
                    commands: filteredCommands,
                    highlightedIndex: highlightedCommandIndex,
                    acceptAction: acceptSlashCommandAction
                )
                .padding(.top, L5Spacing.x2)
            }

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
                    .padding(.top, 44)
            }
        }
        .onChange(of: draft.plainText) { _, _ in
            highlightedCommandIndex = 0
        }
    }

    private var statusMessage: String? {
        if let runtimeMessage, !runtimeMessage.isEmpty {
            return runtimeMessage
        }
        switch availability {
        case let .unavailable(message), let .disconnected(message):
            return message
        case .connecting:
            return "Starting agent runtime..."
        case .available:
            return nil
        }
    }

    private var filteredCommands: [ComposerCommand] {
        guard let token = draft.plainText.currentSlashToken else { return [] }
        let query = String(token.dropFirst()).lowercased()
        guard !query.isEmpty else { return slashCommands }
        return slashCommands.filter { command in
            command.name.lowercased().contains(query) || command.label.lowercased().contains(query)
        }
    }

    private func acceptHighlightedCommand() -> Bool {
        let commands = filteredCommands
        guard !commands.isEmpty else { return false }
        let index = min(max(highlightedCommandIndex, 0), commands.count - 1)
        acceptSlashCommandAction(commands[index])
        highlightedCommandIndex = 0
        return true
    }
}

private struct SendButton: View {
    let isEnabled: Bool
    let isRunning: Bool
    let sendAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        Button(action: isRunning ? cancelAction : sendAction) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: L5Size.icon, weight: .medium))
                .frame(width: L5Size.hitTarget, height: L5Size.hitTarget)
                .background(sendBackground, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !isRunning)
        .opacity((isEnabled || isRunning) ? 1 : 0.58)
        .keyboardShortcut(.return, modifiers: [])
        .help(isRunning ? "Stop agent turn" : "Send")
    }

    private var sendBackground: Color {
        if isRunning { return L5Color.warning }
        return isEnabled ? L5Color.accent : Color(nsColor: .tertiaryLabelColor)
    }
}

private struct PlanChip: View {
    let plan: AgentPlanState
    let isRunning: Bool
    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: L5Spacing.x2) {
                Image(systemName: plan.isComplete ? "checkmark.circle.fill" : "circle.dotted")
                    .symbolEffect(.pulse, options: .repeating, isActive: isRunning && !plan.isComplete)
                    .foregroundStyle(plan.isComplete ? Color(nsColor: .systemGreen) : L5Color.accent)

                Text("Plan \(plan.completedCount)/\(plan.totalCount)")
                    .font(L5Font.caption)
                    .foregroundStyle(L5Color.textPrimary)
            }
            .padding(.horizontal, L5Spacing.x3)
            .padding(.vertical, L5Spacing.x1)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(L5Color.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            PlanPopover(plan: plan)
        }
        .help("Show plan")
    }
}

private struct PlanPopover: View {
    let plan: AgentPlanState

    var body: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x3) {
            Text(plan.title)
                .font(L5Font.h3)
                .foregroundStyle(L5Color.textPrimary)

            VStack(alignment: .leading, spacing: L5Spacing.x2) {
                ForEach(plan.entries) { entry in
                    HStack(alignment: .top, spacing: L5Spacing.x2) {
                        Image(systemName: icon(for: entry.status))
                            .foregroundStyle(color(for: entry.status))
                            .frame(width: L5Size.icon)

                        Text(entry.content)
                            .font(L5Font.body)
                            .foregroundStyle(L5Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(L5Spacing.x4)
        .frame(width: 340, alignment: .leading)
    }

    private func icon(for status: String) -> String {
        switch AgentTranscriptStatusNormalizer.normalized(status) {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        case "failed": "xmark.circle.fill"
        case "cancelled": "minus.circle.fill"
        default: "circle"
        }
    }

    private func color(for status: String) -> Color {
        switch AgentTranscriptStatusNormalizer.normalized(status) {
        case "completed": Color(nsColor: .systemGreen)
        case "in_progress": L5Color.accent
        case "failed": Color(nsColor: .systemRed)
        case "cancelled": .secondary
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

private struct ContextUsageRing: View {
    let usage: AgentTranscriptUsage
    let size: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var showsPopover = false

    private var used: Int { max(usage.used ?? 0, 0) }
    private var fraction: Double { min(max(Double(used) / Double(size), 0), 1) }
    private var left: Int { max(size - used, 0) }

    var body: some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .background {
                Circle()
                    .stroke(L5Color.border, lineWidth: 3)
            }
            .frame(width: 22, height: 22)
            .scaleEffect(!reduceMotion && fraction >= 0.7 && pulse ? pulseScale : 1)
            .animation(.easeInOut(duration: 0.25), value: fraction)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .onHover { showsPopover = $0 }
            .focusable()
            .onTapGesture { showsPopover.toggle() }
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: L5Spacing.x1) {
                    Text("\(fraction.formatted(.percent.precision(.fractionLength(0)))) used")
                        .font(L5Font.h3)
                    Text("\(left.formatted()) tokens left")
                        .font(L5Font.caption)
                        .foregroundStyle(.secondary)
                    Text("\(used.formatted()) / \(size.formatted()) tokens")
                        .font(L5Font.caption)
                        .foregroundStyle(.secondary)
                    if let amount = usage.amount {
                        Text(costText(amount))
                            .font(L5Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(L5Spacing.x3)
            }
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    private var color: Color {
        if fraction >= 0.9 { return Color(nsColor: .systemRed) }
        if fraction >= 0.7 { return L5Color.warning }
        return L5Color.accent
    }

    private var pulseScale: CGFloat {
        fraction >= 0.9 ? 1.16 : 1.08
    }

    private var helpText: String {
        var lines = [
            "\(fraction.formatted(.percent.precision(.fractionLength(0)))) used",
            "\(used.formatted()) / \(size.formatted()) tokens",
            "\(left.formatted()) tokens left"
        ]
        if !usage.text.isEmpty, usage.amount != nil {
            lines.append(usage.text)
        }
        return lines.joined(separator: "\n")
    }

    private func costText(_ amount: Double) -> String {
        if let currency = usage.currency {
            return "\(currency) \(amount.formatted(.number.precision(.fractionLength(3))))"
        }
        return amount.formatted(.number.precision(.fractionLength(3)))
    }
}

private struct PromptQueueView: View {
    let queuedPrompts: [QueuedPrompt]
    let removeAction: (QueuedPrompt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x1) {
            ForEach(queuedPrompts) { prompt in
                HStack(spacing: L5Spacing.x2) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .foregroundStyle(.secondary)
                        .frame(width: L5Size.icon)

                    Text(prompt.text)
                        .font(L5Font.caption)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Button {
                        removeAction(prompt)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: L5Size.action, height: L5Size.action)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove queued prompt")
                }
                .padding(.horizontal, L5Spacing.x3)
                .padding(.vertical, L5Spacing.x2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: L5Radius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: L5Radius.small, style: .continuous)
                        .stroke(L5Color.border, lineWidth: 1)
                }
            }
        }
    }
}

private struct RuntimeStatusView: View {
    let message: String

    var body: some View {
        HStack(spacing: L5Spacing.x2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(L5Font.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.bottom, L5Spacing.x1)
    }
}

private struct MultilineComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let acceptAutocompleteAction: () -> Bool
    let heightChanged: (CGFloat) -> Void
    let submitAction: () -> Void
    private let minLineHeight: CGFloat = L5Spacing.x6
    private let maxLineCount: CGFloat = L5Spacing.x3

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            acceptAutocompleteAction: acceptAutocompleteAction,
            heightChanged: heightChanged,
            minLineHeight: minLineHeight,
            maxLineCount: maxLineCount,
            submitAction: submitAction
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerTextScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.keyHandler = context.coordinator.handleKey
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.measureHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        }
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        context.coordinator.measureHeight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        private let acceptAutocompleteAction: () -> Bool
        private let heightChanged: (CGFloat) -> Void
        private let minLineHeight: CGFloat
        private let maxLineCount: CGFloat
        private let submitAction: () -> Void
        weak var textView: NSTextView?
        private var lastMeasuredHeight: CGFloat = 0

        init(
            text: Binding<String>,
            acceptAutocompleteAction: @escaping () -> Bool,
            heightChanged: @escaping (CGFloat) -> Void,
            minLineHeight: CGFloat,
            maxLineCount: CGFloat,
            submitAction: @escaping () -> Void
        ) {
            _text = text
            self.acceptAutocompleteAction = acceptAutocompleteAction
            self.heightChanged = heightChanged
            self.minLineHeight = minLineHeight
            self.maxLineCount = maxLineCount
            self.submitAction = submitAction
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            measureHeight()
        }

        func measureHeight() {
            guard let textView else { return }
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
            if let scrollView = textView.enclosingScrollView {
                textContainer.containerSize = NSSize(
                    width: max(scrollView.contentSize.width, 1),
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            let measured = min(max(usedHeight, minLineHeight), minLineHeight * maxLineCount)
            guard abs(measured - lastMeasuredHeight) > 0.5 else { return }
            lastMeasuredHeight = measured
            let heightChanged = heightChanged
            Task { @MainActor in
                heightChanged(measured)
            }
        }

        func handleKey(_ event: NSEvent) -> Bool {
            let isReturn = event.keyCode == 36
            let isTab = event.keyCode == 48
            guard isReturn || isTab else { return false }
            if acceptAutocompleteAction() {
                return true
            }
            guard isReturn else { return false }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                return false
            }
            submitAction()
            return true
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

private final class ComposerTextScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private struct AddMenu: View {
    let commands: [ComposerCommand]
    let addAttachmentsAction: ([URL], ComposerAttachment.Kind) -> Void
    let acceptSlashCommandAction: (ComposerCommand) -> Void

    var body: some View {
        Menu {
            Button("Add file", systemImage: "doc.badge.plus") {
                chooseURLs(kind: .file)
            }

            if !commands.isEmpty {
                Divider()
                ForEach(commands) { command in
                    Button(command.label, systemImage: command.systemImage) {
                        acceptSlashCommandAction(command)
                    }
                    .help(command.commandDescription ?? command.rawText)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: L5Size.icon, weight: .regular))
                .frame(width: L5Size.hitTarget, height: L5Size.hitTarget)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .frame(width: L5Size.hitTarget, height: L5Size.hitTarget, alignment: .leading)
        .help("Add")
    }

    private func chooseURLs(kind: ComposerAttachment.Kind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = kind == .file
        panel.canChooseDirectories = kind == .folder
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            addAttachmentsAction(panel.urls, kind)
        }
    }
}

private struct ApprovalModeSelector: View {
    let selectedMode: ApprovalMode
    let selectAction: (ApprovalMode) -> Void

    var body: some View {
        Menu {
            ForEach(ApprovalMode.allCases) { mode in
                Button(mode.label) {
                    selectAction(mode)
                }
            }
        } label: {
            HStack(spacing: L5Spacing.x1) {
                Image(systemName: systemImage)
                    .frame(width: L5Size.icon)
                Text(selectedMode.label)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(L5Font.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, L5Spacing.x2)
            .frame(height: L5Size.hitTarget)
            .contentShape(RoundedRectangle(cornerRadius: L5Radius.button, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help("Approval mode")
    }

    private var systemImage: String {
        switch selectedMode {
        case .ask:
            "person.crop.circle.badge.questionmark"
        case .approveForMe:
            "checkmark.seal"
        case .fullAccess:
            "lock.open"
        }
    }
}

private struct ModelSelector: View {
    @Binding var selectedModelId: String?
    let options: [ComposerModelOption]
    let isSaving: Bool

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(option.label) {
                    selectedModelId = option.id
                }
                .help(option.modelDescription ?? option.id)
            }
        } label: {
            HStack(spacing: L5Spacing.x1) {
                Text(selectedLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(L5Font.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, L5Spacing.x2)
            .frame(height: L5Size.hitTarget)
            .contentShape(RoundedRectangle(cornerRadius: L5Radius.button, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .overlay(alignment: .trailing) {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, L5Spacing.x2)
            }
        }
    }

    private var selectedLabel: String {
        guard let selectedModelId else {
            return options.first?.label ?? "Model"
        }
        return options.first(where: { $0.id == selectedModelId })?.label ?? ComposerModelOption(id: selectedModelId).label
    }
}

private struct PermissionTakeoverView: View {
    let request: PermissionRequest
    @Binding var highlightedIndex: Int
    @Binding var instructionText: String
    let respondAction: (String) -> Void
    let rejectWithInstructionsAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: L5Spacing.x3) {
            HStack(alignment: .top, spacing: L5Spacing.x3) {
                Image(systemName: "hand.raised")
                    .font(.system(size: L5Size.icon, weight: .semibold))
                    .foregroundStyle(L5Color.warning)
                    .frame(width: L5Size.action)

                VStack(alignment: .leading, spacing: L5Spacing.x1) {
                    Text(request.title)
                        .font(L5Font.body)
                        .foregroundStyle(L5Color.textPrimary)
                        .lineLimit(2)

                    if let summary {
                        Text(summary)
                            .font(L5Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if let detailText {
                Text(detailText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(L5Spacing.x2)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: L5Radius.small, style: .continuous))
            }

            VStack(spacing: L5Spacing.x1) {
                ForEach(Array(request.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        respondAction(option.optionId)
                    } label: {
                        HStack(spacing: L5Spacing.x3) {
                            Image(systemName: option.isAllowLike ? "checkmark.circle" : option.isRejectLike ? "xmark.circle" : "circle")
                                .frame(width: L5Size.icon)
                                .foregroundStyle(option.isAllowLike ? L5Color.success : option.isRejectLike ? L5Color.warning : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.name)
                                    .font(L5Font.caption)
                                    .foregroundStyle(L5Color.textPrimary)
                                if let kind = option.kind {
                                    Text(kind)
                                        .font(L5Font.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, L5Spacing.x2)
                        .frame(height: 42)
                        .background {
                            if index == highlightedIndex {
                                RoundedRectangle(cornerRadius: L5Radius.small, style: .continuous)
                                    .fill(Color(nsColor: .controlAccentColor).opacity(0.16))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .focusable()
            .onMoveCommand { direction in
                guard !request.options.isEmpty else { return }
                switch direction {
                case .up:
                    highlightedIndex = max(0, highlightedIndex - 1)
                case .down:
                    highlightedIndex = min(request.options.count - 1, highlightedIndex + 1)
                default:
                    break
                }
            }
            .background(
                PermissionKeyHandler(
                    moveUp: {
                        highlightedIndex = max(0, highlightedIndex - 1)
                    },
                    moveDown: {
                        highlightedIndex = min(max(request.options.count - 1, 0), highlightedIndex + 1)
                    },
                    accept: {
                        guard request.options.indices.contains(highlightedIndex) else { return }
                        respondAction(request.options[highlightedIndex].optionId)
                    }
                )
            )

            HStack(spacing: L5Spacing.x2) {
                TextField("Instructions after rejecting", text: $instructionText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)

                Button {
                    rejectWithInstructionsAction(instructionText)
                    instructionText = ""
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .frame(width: L5Size.hitTarget, height: L5Size.hitTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Reject and send instructions")
            }
        }
        .onAppear {
            highlightedIndex = min(highlightedIndex, max(request.options.count - 1, 0))
        }
    }

    private var summary: String? {
        [request.toolKind, request.toolStatus].compactMap { $0 }.joined(separator: " - ").nonEmpty
    }

    private var detailText: String? {
        request.detail?.nonEmpty ?? request.rawInput?.nonEmpty
    }
}

private struct PermissionKeyHandler: NSViewRepresentable {
    let moveUp: () -> Void
    let moveDown: () -> Void
    let accept: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.moveUpAction = moveUp
        view.moveDownAction = moveDown
        view.acceptAction = accept
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.moveUpAction = moveUp
        view.moveDownAction = moveDown
        view.acceptAction = accept
    }

    final class KeyView: NSView {
        var moveUpAction: (() -> Void)?
        var moveDownAction: (() -> Void)?
        var acceptAction: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36:
                acceptAction?()
            case 53:
                break
            case 125:
                moveDownAction?()
            case 126:
                moveUpAction?()
            default:
                super.keyDown(with: event)
            }
        }
    }
}

private struct AttachmentChipsView: View {
    let chips: [ComposerAttachmentChip]
    let removeAction: (ComposerAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: L5Spacing.x3) {
                ForEach(chips) { chip in
                    HStack(spacing: L5Spacing.x3) {
                        ZStack {
                            RoundedRectangle(cornerRadius: L5Radius.medium, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                            Image(systemName: "doc.text")
                                .font(.system(size: L5Size.action, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 56, height: 56)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(chip.attachment.basename)
                                .font(L5Font.body)
                                .foregroundStyle(L5Color.textPrimary)
                                .lineLimit(1)

                            Text(chip.attachment.fileExtensionLabel)
                                .font(L5Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 110, maxWidth: 180, alignment: .leading)

                        Spacer(minLength: 0)

                        Button {
                            removeAction(chip.attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(nsColor: .labelColor), Color(nsColor: .controlBackgroundColor))
                    }
                    .padding(L5Spacing.x2)
                    .frame(width: 260, height: 82)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: L5Radius.input, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: L5Radius.input, style: .continuous)
                            .stroke(L5Color.border, lineWidth: 1)
                    }
                    .help(chip.attachment.url.path)
                }
            }
        }
    }
}

private struct SlashCommandAutocomplete: View {
    let commands: [ComposerCommand]
    let highlightedIndex: Int
    let acceptAction: (ComposerCommand) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(commands.prefix(maxVisibleCommands).enumerated()), id: \.element.id) { index, command in
                Button {
                    acceptAction(command)
                } label: {
                    HStack(spacing: L5Spacing.x3) {
                        Image(systemName: command.systemImage)
                            .font(.system(size: L5Size.icon, weight: .medium))
                            .frame(width: L5Size.action)
                            .foregroundStyle(.secondary)

                        HStack(spacing: L5Spacing.x2) {
                            Text(command.label)
                                .font(L5Font.caption)
                                .foregroundStyle(L5Color.textPrimary)
                            if let description = command.commandDescription {
                                Text(description)
                                    .font(L5Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)

                        Text(command.inputHint ?? "Command")
                            .font(L5Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, L5Spacing.x4)
                    .frame(height: 44)
                    .background {
                        if index == highlightedIndex {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .controlAccentColor).opacity(0.16))
                        }
                    }
                }
                .buttonStyle(.plain)
                }
            }
        }
        .frame(height: popupHeight)
        .padding(.vertical, L5Spacing.x1)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: L5Radius.input, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: L5Radius.input, style: .continuous)
                .stroke(L5Color.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
        .zIndex(20)
    }

    private var popupHeight: CGFloat {
        let visibleCount = min(commands.count, maxVisibleCommands)
        return min(CGFloat(visibleCount) * 44 + L5Spacing.x2, 350)
    }

    private var maxVisibleCommands: Int {
        Int(L5Spacing.x3)
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
        HStack(spacing: L5Spacing.x6) {
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
        .padding(.horizontal, L5Spacing.x4)
        .padding(.top, L5Spacing.x3)
        .padding(.bottom, L5Spacing.x4)
    }

    private var projectTitle: String {
        selectedProject?.displayName ?? "Choose project"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var currentSlashToken: Substring? {
        guard let slashIndex = lastIndex(of: "/") else { return nil }
        let token = self[slashIndex...]
        guard token.dropFirst().allSatisfy({ !$0.isWhitespace }) else { return nil }
        if slashIndex > startIndex {
            let previous = index(before: slashIndex)
            guard self[previous].isWhitespace else { return nil }
        }
        return token
    }
}

private extension ComposerAttachment {
    var fileExtensionLabel: String {
        let pathExtension = url.pathExtension
        return pathExtension.isEmpty ? "FILE" : pathExtension.uppercased()
    }
}

private struct FooterItem: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: L5Spacing.x2) {
            Image(systemName: systemImage)
                .frame(width: L5Size.icon)

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
                        .frame(width: L5Size.icon)

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
                    .frame(width: L5Size.action, height: L5Size.action)
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
                    .frame(width: L5Size.icon)
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
