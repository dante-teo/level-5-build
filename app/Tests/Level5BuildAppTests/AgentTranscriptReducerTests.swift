import Testing
@testable import Level5BuildApp

@Suite("Agent transcript reducer")
struct AgentTranscriptReducerTests {
    @Test("Message chunks merge by message id")
    func messageChunksMergeByMessageId() {
        var state = AgentTranscriptState()

        state.apply(.messageChunk(role: .agent, messageId: "m1", text: "Hello"))
        state.apply(.messageChunk(role: .agent, messageId: "m1", text: " world"))

        #expect(state.items.count == 1)
        #expect(state.items.first?.messageText == "Hello world")
    }

    @Test("Same-role contiguous chunks merge without message id")
    func sameRoleFallbackMerges() {
        var state = AgentTranscriptState()

        state.apply(.messageChunk(role: .agent, messageId: nil, text: "A"))
        state.apply(.messageChunk(role: .agent, messageId: nil, text: "B"))
        state.apply(.messageChunk(role: .user, messageId: nil, text: "C"))

        #expect(state.items.map(\.messageText) == ["AB", "C"])
    }

    @Test("Unsupported-only message blocks render from unsupported count only")
    func unsupportedOnlyMessageBlocksDoNotDuplicatePlaceholderText() {
        var state = AgentTranscriptState()

        state.apply(.messageChunk(role: .agent, messageId: "m1", text: "", unsupportedBlockCount: 1))

        #expect(state.items.count == 1)
        #expect(state.items.first?.messageText == "")
        #expect(state.items.first?.unsupportedBlockCount == 1)
    }

    @Test("Plan updates replace the active plan item")
    func planUpdatesReplaceActiveItem() {
        var state = AgentTranscriptState()

        state.apply(.plan(status: "in_progress", text: "First"))
        state.apply(.plan(status: "completed", text: "Second"))

        #expect(state.items.count == 1)
        #expect(state.items.first?.planText == "Second")
        #expect(state.items.first?.planStatus == "completed")
    }

    @Test("Tool updates merge partial fields by tool call id")
    func toolUpdatesMergeByToolCallId() {
        var state = AgentTranscriptState()

        state.apply(.tool(toolCallId: "t1", title: "Read file", kind: "read", status: "pending", text: "Starting"))
        state.apply(.tool(toolCallId: "t1", title: nil, kind: nil, status: "completed", text: nil))

        #expect(state.items.count == 1)
        #expect(state.items.first?.toolTitle == "Read file")
        #expect(state.items.first?.toolKind == "read")
        #expect(state.items.first?.toolStatus == "completed")
        #expect(state.items.first?.toolText == "Starting")
    }

    @Test("Usage updates replace latest usage and metadata")
    func usageUpdatesReplaceLatestUsage() {
        var state = AgentTranscriptState()

        state.apply(.usage(.init(used: 10, size: 100, amount: nil, currency: nil)))
        state.apply(.usage(.init(used: 20, size: 100, amount: 0.01, currency: "USD")))

        #expect(state.items.count == 1)
        #expect(state.latestUsage?.used == 20)
        #expect(state.latestUsage?.currency == "USD")
    }

    @Test("Status and error replacement keys replace matching rows")
    func statusAndErrorReplacementKeysReplaceRows() {
        var state = AgentTranscriptState()

        state.apply(.status(title: "Runtime", text: "Connecting", replacementKey: "runtime"))
        state.apply(.status(title: "Runtime", text: "Connected", replacementKey: "runtime"))
        state.apply(.error(title: "Prompt failed", text: "First", replacementKey: "prompt"))
        state.apply(.error(title: "Prompt failed", text: "Second", replacementKey: "prompt"))

        #expect(state.items.count == 2)
        #expect(state.items.first?.statusText == "Connected")
        #expect(state.items.last?.errorText == "Second")
        #expect(state.latestError == "Second")
    }

    @Test("Ordinary end turn is stored but not rendered")
    func ordinaryEndTurnDoesNotRender() {
        var state = AgentTranscriptState()

        state.apply(.stopReason("end_turn"))

        #expect(state.stopReasons == ["end_turn"])
        #expect(state.renderableItems.isEmpty)
    }

    @Test("Notable stop reasons render compact status rows")
    func notableStopsRender() {
        var state = AgentTranscriptState()

        state.apply(.stopReason("cancelled"))
        state.apply(.stopReason("refusal"))
        state.apply(.stopReason("max_tokens"))

        #expect(state.stopReasons == ["cancelled", "refusal", "max_tokens"])
        #expect(state.renderableItems.count == 3)
        #expect(state.renderableItems.map(\.statusText) == [
            "Agent turn ended: cancelled.",
            "Agent turn ended: refusal.",
            "Agent turn ended: max_tokens."
        ])
    }
}

private extension AgentTranscriptItem {
    var messageText: String? {
        guard case let .message(message) = kind else { return nil }
        return message.text
    }

    var unsupportedBlockCount: Int? {
        guard case let .message(message) = kind else { return nil }
        return message.unsupportedBlockCount
    }

    var planText: String? {
        guard case let .plan(plan) = kind else { return nil }
        return plan.text
    }

    var planStatus: String? {
        guard case let .plan(plan) = kind else { return nil }
        return plan.status
    }

    var toolTitle: String? {
        guard case let .tool(tool) = kind else { return nil }
        return tool.title
    }

    var toolKind: String? {
        guard case let .tool(tool) = kind else { return nil }
        return tool.kind
    }

    var toolStatus: String? {
        guard case let .tool(tool) = kind else { return nil }
        return tool.status
    }

    var toolText: String? {
        guard case let .tool(tool) = kind else { return nil }
        return tool.text
    }

    var statusText: String? {
        guard case let .status(status) = kind else { return nil }
        return status.text
    }

    var errorText: String? {
        guard case let .error(error) = kind else { return nil }
        return error.text
    }
}
