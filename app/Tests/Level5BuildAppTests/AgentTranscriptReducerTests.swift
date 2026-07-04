import Foundation
import Testing
import Level5Core
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

    @Test("Plan updates populate structured state without transcript rows")
    func planUpdatesPopulateStateOnly() {
        var state = AgentTranscriptState()

        state.apply(.plan(entries: [
            .init(id: "1", content: "First", status: "in_progress", priority: "high"),
            .init(id: "2", content: "Second", status: "pending", priority: "medium")
        ]))

        #expect(state.items.isEmpty)
        #expect(state.renderableItems.isEmpty)
        #expect(state.plan?.completedCount == 0)
        #expect(state.plan?.totalCount == 2)
        #expect(state.plan?.entries.map(\.content) == ["First", "Second"])
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
        #expect(state.items.first?.toolIsExpanded == false)
    }

    @Test("Tool expansion follows active completed failed and manual choices")
    func toolExpansionRules() {
        var state = AgentTranscriptState()

        state.apply(.tool(toolCallId: "t1", title: "Run tests", kind: "execute", status: "in_progress", text: "Working"))
        #expect(state.items.first?.toolIsExpanded == true)

        state.apply(.toolExpansion(toolCallId: "t1", isExpanded: true))
        state.apply(.tool(toolCallId: "t1", title: nil, kind: nil, status: "completed", text: "Done"))
        #expect(state.items.first?.toolIsExpanded == true)

        state.apply(.toolExpansion(toolCallId: "t1", isExpanded: false))
        #expect(state.items.first?.toolIsExpanded == false)

        state.apply(.tool(toolCallId: "t1", title: nil, kind: nil, status: "failed", text: "Failed"))
        #expect(state.items.first?.toolIsExpanded == true)
    }

    @Test("Usage updates replace latest usage without transcript rows")
    func usageUpdatesReplaceLatestUsage() {
        var state = AgentTranscriptState()

        state.apply(.usage(.init(used: 10, size: 100, amount: nil, currency: nil)))
        state.apply(.usage(.init(used: 20, size: 100, amount: 0.01, currency: "USD")))

        #expect(state.items.isEmpty)
        #expect(state.renderableItems.isEmpty)
        #expect(state.latestUsage?.used == 20)
        #expect(state.latestUsage?.currency == "USD")
    }

    @Test("References dedupe by kind and URI while preserving first title")
    func referencesDedupeByIdentity() {
        var state = AgentTranscriptState()
        let fileURI = URL(fileURLWithPath: "/tmp/runbook.md").absoluteString

        state.apply(.references([
            .init(kind: .web, title: "ACP docs", uri: "https://example.com/acp"),
            .init(kind: .web, title: "Duplicate ACP docs", uri: "https://example.com/acp"),
            .init(kind: .file, title: "Runbook", uri: fileURI),
            .init(kind: .file, title: "Duplicate runbook", uri: fileURI)
        ]))

        #expect(state.references.map(\.title) == ["ACP docs", "Runbook"])
        #expect(state.references.map(\.uri) == ["https://example.com/acp", fileURI])
        #expect(Set(state.references.map(\.id)).count == state.references.count)
    }

    @Test("Tool metadata references dedupe by kind and URI")
    func toolMetadataReferencesDedupeByIdentity() throws {
        let payload = """
        {
          "sessionId": "s1",
          "update": {
            "sessionUpdate": "tool_call_update",
            "toolCallId": "fetch-1",
            "title": "Fetch docs",
            "status": "completed",
            "_meta": {
              "references": [
                { "title": "ACP docs", "uri": "https://example.com/acp" },
                { "title": "Duplicate ACP docs", "uri": "https://example.com/acp" },
                { "title": "Runbook", "uri": "file:///tmp/runbook.md" },
                { "title": "Duplicate runbook", "uri": "file:///tmp/runbook.md" }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let update = try AcpProtocolCoding.decoder.decode(AcpSessionUpdate.self, from: payload)

        let events = AgentTranscriptNormalizer.events(from: update)
        guard case let .references(references)? = events.last else {
            Issue.record("Expected references event")
            return
        }

        #expect(references.map(\.title) == ["ACP docs", "Runbook"])
        #expect(references.map(\.uri) == ["https://example.com/acp", "file:///tmp/runbook.md"])
        #expect(Set(references.map(\.id)).count == references.count)
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

    var toolIsExpanded: Bool? {
        guard case let .tool(tool) = kind else { return nil }
        return tool.isExpanded
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
