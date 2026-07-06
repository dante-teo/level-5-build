import Foundation
import Testing
import Level5Core

@Suite("ACP JSON-RPC transport", .serialized)
struct AcpTransportTests {
    @Test("Correlates responses to requests")
    func correlatesResponses() async throws {
        let harness = TransportHarness()
        let request = Task { try await harness.transport.request(method: "initialize", params: ["protocolVersion": 1]) }

        let sent = try await harness.nextSent()
        #expect(sent["method"]?.stringValue == "initialize")
        await harness.transport.handleLine(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#)

        let result = try await request.value
        #expect(result == ["ok": true])
    }

    @Test("Delivers notifications and server requests as events")
    func deliversEvents() async throws {
        let harness = TransportHarness()
        let events = EventCollector(harness.transport.events)

        await harness.transport.handleLine(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"plan"}}}"#)
        await harness.transport.handleLine(#"{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"s1"}}"#)

        let notification = try await events.nextNotification()
        #expect(notification.method == "session/update")
        let request = try await events.nextServerRequest()
        #expect(request.id == .int(42))
        #expect(request.method == "session/request_permission")
    }

    @Test("Reports malformed JSON and invalid envelopes without crashing")
    func reportsMalformedMessages() async throws {
        let harness = TransportHarness()
        let events = EventCollector(harness.transport.events)

        await harness.transport.handleLine("{not-json")
        await harness.transport.handleLine(#"{"jsonrpc":"1.0","id":1,"result":{}}"#)

        let first = try await events.nextDiagnostic()
        let second = try await events.nextDiagnostic()
        #expect(first.level == .error)
        #expect(second.message.contains("invalid JSON-RPC version"))
    }

    @Test("Request timeout removes pending continuation")
    func requestTimeout() async throws {
        let harness = TransportHarness(timeout: .milliseconds(20))

        await #expect(throws: AcpTransportError.self) {
            _ = try await harness.transport.request(method: "slow")
        }

        await harness.transport.handleLine(#"{"jsonrpc":"2.0","id":1,"result":{"late":true}}"#)
        let events = EventCollector(harness.transport.events)
        let diagnostic = try await events.nextDiagnostic()
        #expect(diagnostic.message.contains("unexpected response id"))
    }

    @Test("session/prompt is not bound by the transport's short default request timeout")
    func promptIgnoresShortDefaultTimeout() async throws {
        // A real agent turn (tool calls, edits, etc.) routinely takes far
        // longer than the short default meant for quick RPCs like
        // `initialize`. `AcpClient.prompt` must use its own generous
        // timeout instead of the transport's default, or a legitimately
        // long-running turn gets reported as "Prompt failed" while the
        // agent is still working — see `AcpClient.prompt`.
        let harness = TransportHarness(timeout: .milliseconds(20))
        let client = AcpClient(transport: harness.transport)

        let request = Task {
            try await client.prompt(.init(sessionId: "s1", prompt: []))
        }
        _ = try await harness.nextSent()

        // Outlive the transport's short default timeout by several times
        // over before finally responding: if `prompt` were bound by that
        // default, awaiting below would throw `requestTimedOut` instead of
        // succeeding.
        try await Task.sleep(for: .milliseconds(100))
        await harness.transport.handleLine(#"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#)
        let result = try await request.value
        #expect(result.stopReason == "end_turn")
    }

    @Test("Task cancellation removes pending continuation")
    func taskCancellation() async throws {
        let harness = TransportHarness(timeout: .seconds(5))
        let task = Task {
            _ = try await harness.transport.request(method: "slow")
        }
        _ = try await harness.nextSent()
        task.cancel()

        await #expect(throws: AcpTransportError.self) {
            try await task.value
        }

        await harness.transport.handleLine(#"{"jsonrpc":"2.0","id":1,"result":{"late":true}}"#)
        let events = EventCollector(harness.transport.events)
        let diagnostic = try await events.nextDiagnostic()
        #expect(diagnostic.message.contains("unexpected response id"))
    }

    @Test("failAll rejects pending requests")
    func failAllRejectsPendingRequests() async throws {
        let harness = TransportHarness()
        let task = Task { try await harness.transport.request(method: "initialize") }
        _ = try await harness.nextSent()

        await harness.transport.failAll(AcpTransportError.failed("boom"))

        await #expect(throws: AcpTransportError.self) {
            _ = try await task.value
        }
    }

    @Test("Stderr, process exit, and oversized stdout lines are surfaced")
    func diagnosticsAndProcessEvents() async throws {
        let harness = TransportHarness(maxLineBytes: 8)
        let events = EventCollector(harness.transport.events)

        await harness.transport.emitStderr("stderr line")
        await harness.transport.emitProcessExit(status: 9, reason: "exit")

        let stderr = try await events.nextStderr()
        let exit = try await events.nextExit()
        #expect(stderr == "stderr line")
        #expect(exit.status == 9)

        let oversized = TransportHarness(maxLineBytes: 8)
        let oversizedEvents = EventCollector(oversized.transport.events)
        await oversized.transport.handleLine(#"{"jsonrpc":"2.0"}"#)
        let diagnostic = try await oversizedEvents.nextDiagnostic()
        #expect(diagnostic.message.contains("exceeded"))
    }
}

@Suite("ACP process transport")
struct AcpProcessTransportTests {
    @Test("Launches the Node mock server when dependencies are available")
    func launchesMockServer() async throws {
        guard ProcessInfo.processInfo.environment["LEVEL5_RUN_ACP_PROCESS_INTEGRATION"] == "1" else {
            print("Skipping mock integration: set LEVEL5_RUN_ACP_PROCESS_INTEGRATION=1 to launch acp-mock-server/start.sh")
            return
        }

        let repoRoot = try #require(findRepoRoot(), "Could not locate repository root")
        let mockRoot = repoRoot.appendingPathComponent("acp-mock-server", isDirectory: true)
        let startScript = mockRoot.appendingPathComponent("start.sh")

        guard FileManager.default.isExecutableFile(atPath: startScript.path) else {
            print("Skipping mock integration: acp-mock-server/start.sh is not executable")
            return
        }
        guard FileManager.default.fileExists(atPath: mockRoot.appendingPathComponent("node_modules").path) else {
            print("Skipping mock integration: acp-mock-server dependencies are not installed")
            return
        }

        let process = AcpProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [startScript.path],
            environment: [
                "ACP_MOCK_STATE_PATH": FileManager.default.temporaryDirectory
                    .appendingPathComponent("level5-acp-\(UUID().uuidString).json").path,
                "ACP_MOCK_DELAY_MS": "0",
                "ACP_MOCK_LOG": "silent"
            ],
            currentDirectoryURL: mockRoot,
            requestTimeout: .seconds(3)
        )
        try process.start()
        defer { process.terminate() }

        let client = AcpClient(transport: process.transport)
        let result = try await withTimeout(.seconds(5)) {
            try await client.initialize(.init(clientInfo: .init(name: "Level5CoreTests", version: "0.0.0")))
        }

        #expect(result.protocolVersion == 1)
        #expect(result.agentInfo?.name == "devin-mock-agent")
    }
}

private func withTimeout<T: Sendable>(_ duration: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let completion = ResumeOnce<T>()
    let operationTask = Task {
        do {
            await completion.resume(returning: try await operation())
        } catch {
            await completion.resume(throwing: error)
        }
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: duration)
        await completion.resume(throwing: AcpTransportTestError.timeout)
    }

    do {
        let value = try await completion.value()
        timeoutTask.cancel()
        operationTask.cancel()
        return value
    } catch {
        timeoutTask.cancel()
        operationTask.cancel()
        throw error
    }
}

private actor ResumeOnce<T: Sendable> {
    private var result: Result<T, Error>?
    private var continuations: [CheckedContinuation<T, Error>] = []

    func resume(returning value: T) {
        complete(.success(value))
    }

    func resume(throwing error: Error) {
        complete(.failure(error))
    }

    func value() async throws -> T {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    private func complete(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let continuations = self.continuations
        self.continuations = []
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }
}

private func findRepoRoot() -> URL? {
    var candidate = URL(fileURLWithPath: #filePath)
    for _ in 0..<8 {
        candidate.deleteLastPathComponent()
        let startScript = candidate
            .appendingPathComponent("acp-mock-server", isDirectory: true)
            .appendingPathComponent("start.sh")
        if FileManager.default.fileExists(atPath: startScript.path) {
            return candidate
        }
    }
    return nil
}

private actor SentLines {
    private var lines: [String] = []
    private var continuations: [CheckedContinuation<String, Error>] = []

    func append(_ line: String) {
        if continuations.isEmpty {
            lines.append(line)
        } else {
            continuations.removeFirst().resume(returning: line)
        }
    }

    func next(timeout: Duration = .seconds(5)) async throws -> String {
        return try await withTimeout(timeout) {
            try await self.dequeue()
        }
    }

    private func dequeue() async throws -> String {
        if !lines.isEmpty {
            return lines.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            enqueue(continuation)
        }
    }

    private func enqueue(_ continuation: CheckedContinuation<String, Error>) {
        continuations.append(continuation)
    }
}

private struct TransportHarness {
    let sent = SentLines()
    let transport: AcpJsonRpcTransport

    init(timeout: Duration = .seconds(1), maxLineBytes: Int = 1_048_576) {
        let sent = sent
        transport = AcpJsonRpcTransport(maxLineBytes: maxLineBytes, requestTimeout: timeout) { line in
            await sent.append(line)
        }
    }

    func nextSent() async throws -> [String: JSONValue] {
        let line = try await sent.next()
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        guard case let .object(object) = value else {
            throw AcpTransportTestError.invalidSentLine
        }
        return object
    }
}

private actor EventCollector {
    private var events: [AcpEvent] = []
    private var continuations: [CheckedContinuation<AcpEvent, Error>] = []

    init(_ events: AsyncStream<AcpEvent>) {
        Task {
            for await event in events {
                await self.append(event)
            }
        }
    }

    func nextNotification() async throws -> (method: String, params: JSONValue?) {
        while let event = try await next() {
            if case let .notification(method, params) = event {
                return (method, params)
            }
        }
        throw AcpTransportTestError.timeout
    }

    func nextServerRequest() async throws -> (id: AcpRpcID, method: String, params: JSONValue?) {
        while let event = try await next() {
            if case let .serverRequest(id, method, params) = event {
                return (id, method, params)
            }
        }
        throw AcpTransportTestError.timeout
    }

    func nextDiagnostic() async throws -> AcpDiagnostic {
        while let event = try await next() {
            if case let .diagnostic(diagnostic) = event {
                return diagnostic
            }
        }
        throw AcpTransportTestError.timeout
    }

    func nextStderr() async throws -> String {
        while let event = try await next() {
            if case let .stderr(line) = event {
                return line
            }
        }
        throw AcpTransportTestError.timeout
    }

    func nextExit() async throws -> AcpProcessExit {
        while let event = try await next() {
            if case let .processExit(exit) = event {
                return exit
            }
        }
        throw AcpTransportTestError.timeout
    }

    private func next(timeout: Duration = .seconds(5)) async throws -> AcpEvent? {
        try await withTimeout(timeout) {
            try await self.dequeue()
        }
    }

    private func append(_ event: AcpEvent) {
        if continuations.isEmpty {
            events.append(event)
        } else {
            continuations.removeFirst().resume(returning: event)
        }
    }

    private func dequeue() async throws -> AcpEvent {
        if !events.isEmpty {
            return events.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private enum AcpTransportTestError: Error {
    case invalidSentLine
    case timeout
}
