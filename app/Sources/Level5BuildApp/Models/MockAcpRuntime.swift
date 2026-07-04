import Foundation
import Level5Core

@MainActor
final class MockAcpRuntime {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var pending: [Int: PendingRequest] = [:]
    private var nextId = 1
    private var sessionId: String?
    private var appendAgentText: ((String) -> Void)?
    private var appendStatus: ((String) -> Void)?
    private let environment: [String: String]
    private let requestTimeoutSeconds: UInt64
    private var generation = 0
    private var suppressNextProcessExit = false

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestTimeoutSeconds: UInt64 = 30
    ) {
        self.environment = environment
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    var isEnabled: Bool {
        environment["LEVEL5_USE_ACP_MOCK"] == "1"
    }

    func send(
        prompt: String,
        cwd: String?,
        appendAgentText: @escaping (String) -> Void,
        appendStatus: @escaping (String) -> Void
    ) async {
        self.appendAgentText = appendAgentText
        self.appendStatus = appendStatus
        let sendGeneration = generation

        do {
            try startIfNeeded()
            try await initializeAndCreateSessionIfNeeded(cwd: cwd)
            guard let sessionId else {
                guard sendGeneration == generation else { return }
                self.appendStatus?("ACP mock session was not created.")
                return
            }

            let result = try await request(method: AcpMethod.sessionPrompt, params: [
                "sessionId": .string(sessionId),
                "prompt": [
                    [
                        "type": "text",
                        "text": .string(prompt)
                    ]
                ]
            ])
            let stopReason = result.objectValue?["stopReason"]?.stringValue ?? "unknown"
            guard sendGeneration == generation else { return }
            self.appendStatus?("ACP mock turn ended: \(stopReason).")
        } catch {
            guard sendGeneration == generation else { return }
            self.appendStatus?("ACP mock failed: \(error)")
        }
    }

    func reset() {
        generation += 1
        appendAgentText = nil
        appendStatus = nil
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinHandle?.close()
        if process?.isRunning == true {
            suppressNextProcessExit = true
            process?.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinHandle = nil
        sessionId = nil
        failPending(MockAcpRuntimeError.cancelled)
    }

    private func initializeAndCreateSessionIfNeeded(cwd: String?) async throws {
        guard sessionId == nil else { return }

        _ = try await request(method: AcpMethod.initialize, params: [
            "protocolVersion": 1,
            "clientInfo": [
                "name": "Level5 Build",
                "version": "0.0.0"
            ],
            "clientCapabilities": [:]
        ])
        let session = try await request(method: AcpMethod.sessionNew, params: [
            "cwd": .string(cwd ?? FileManager.default.homeDirectoryForCurrentUser.path),
            "mcpServers": []
        ])
        guard let sessionId = session.objectValue?["sessionId"]?.stringValue else {
            throw MockAcpRuntimeError.missingSessionId
        }
        self.sessionId = sessionId
    }

    private func startIfNeeded() throws {
        guard process == nil else { return }

        let startScript = try resolveMockStartScript()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        let mockRoot = startScript.deletingLastPathComponent()
        if
            let nodePath = environment["LEVEL5_NODE_PATH"],
            !nodePath.isEmpty,
            FileManager.default.fileExists(atPath: mockRoot.appendingPathComponent("dist/src/index.js").path)
        {
            process.executableURL = URL(fileURLWithPath: nodePath)
            process.arguments = [mockRoot.appendingPathComponent("dist/src/index.js").path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [startScript.path]
        }
        process.currentDirectoryURL = mockRoot
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = environment.merging([
            "ACP_MOCK_LOG": environment["ACP_MOCK_LOG"] ?? "silent",
            "ACP_MOCK_STATE_PATH": environment["ACP_MOCK_STATE_PATH"] ?? defaultStatePath()
        ]) { _, new in new }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                if self?.suppressNextProcessExit == true {
                    self?.suppressNextProcessExit = false
                    return
                }
                self?.appendStatus?("ACP mock exited with status \(process.terminationStatus).")
                self?.failPending(MockAcpRuntimeError.processExited)
            }
        }

        try process.run()
        self.process = process
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
        stdinHandle = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in
                self?.consume(data, stream: .stdout)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in
                self?.consume(data, stream: .stderr)
            }
        }
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextId
        nextId += 1
        let message: JSONValue = [
            "jsonrpc": "2.0",
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ]

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: requestTimeoutSeconds * 1_000_000_000)
                completeRequest(id: id, result: .failure(MockAcpRuntimeError.timeout(method)))
            }
            pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)

            do {
                try write(message)
            } catch {
                completeRequest(id: id, result: .failure(error))
            }
        }
    }

    private func respond(id: JSONValue, result: JSONValue) throws {
        try write([
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ])
    }

    private func write(_ message: JSONValue) throws {
        guard let stdinHandle else {
            throw MockAcpRuntimeError.notStarted
        }
        let data = try AcpProtocolCoding.encoder.encode(message)
        stdinHandle.write(data + Data([10]))
    }

    private func handleStdoutLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let message = try AcpProtocolCoding.decoder.decode(JSONValue.self, from: data)
            guard let object = message.objectValue else { return }

            if let id = object["id"], object["result"] != nil || object["error"] != nil {
                handleResponse(id: id, object: object)
            } else if let method = object["method"]?.stringValue {
                if object["id"] != nil {
                    handleServerRequest(method: method, object: object)
                } else {
                    handleNotification(method: method, object: object)
                }
            }
        } catch {
            appendStatus?("ACP mock sent invalid JSON: \(error)")
        }
    }

    private func handleResponse(id: JSONValue, object: [String: JSONValue]) {
        guard case let .number(number) = id else { return }
        let requestId = Int(number)
        if let error = object["error"]?.objectValue {
            let message = error["message"]?.stringValue ?? "JSON-RPC error"
            completeRequest(id: requestId, result: .failure(MockAcpRuntimeError.rpc(message)))
        } else {
            completeRequest(id: requestId, result: .success(object["result"] ?? .null))
        }
    }

    private func handleServerRequest(method: String, object: [String: JSONValue]) {
        guard method == AcpMethod.sessionRequestPermission, let id = object["id"] else { return }
        do {
            try respond(id: id, result: [
                "outcome": [
                    "optionId": "allow-once"
                ]
            ])
        } catch {
            appendStatus?("ACP mock permission response failed: \(error)")
        }
    }

    private func handleNotification(method: String, object: [String: JSONValue]) {
        guard method == AcpMethod.sessionUpdate, let params = object["params"] else { return }
        handleSessionUpdate(params)
    }

    private func handleSessionUpdate(_ params: JSONValue) {
        guard
            let object = params.objectValue,
            let update = object["update"]?.objectValue,
            let updateKind = update["sessionUpdate"]?.stringValue
        else { return }

        switch updateKind {
        case "agent_message_chunk":
            if
                let content = update["content"]?.objectValue,
                content["type"]?.stringValue == "text",
                let text = content["text"]?.stringValue
            {
                appendAgentText?(text)
            }
        case "plan":
            let active = (update["entries"]?.arrayValue ?? []).compactMap { entry -> String? in
                guard let object = entry.objectValue, object["status"]?.stringValue == "in_progress" else {
                    return nil
                }
                return object["content"]?.stringValue
            }
            if let first = active.first {
                appendStatus?("Plan: \(first)")
            }
        case "tool_call":
            if let title = update["title"]?.stringValue {
                appendStatus?("Tool started: \(title)")
            }
        case "tool_call_update":
            if let status = update["status"]?.stringValue {
                appendStatus?("Tool \(status).")
            }
        default:
            break
        }
    }

    private func handleStderrLine(_ line: String) {
        if environment["ACP_MOCK_LOG"] == "debug" {
            appendStatus?("ACP mock stderr: \(line)")
        }
    }

    private func completeRequest(id: Int, result: Result<JSONValue, Error>) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let pending = pending
        self.pending = [:]
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private enum OutputStream {
        case stdout
        case stderr
    }

    private func consume(_ data: Data, stream: OutputStream) {
        switch stream {
        case .stdout:
            stdoutBuffer.append(data)
            for line in drainLines(from: &stdoutBuffer) {
                handleStdoutLine(line)
            }
        case .stderr:
            stderrBuffer.append(data)
            for line in drainLines(from: &stderrBuffer) {
                handleStderrLine(line)
            }
        }
    }

    private func drainLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private func resolveMockStartScript() throws -> URL {
        if let explicit = environment["LEVEL5_ACP_MOCK_START_PATH"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }

        let fileManager = FileManager.default
        let candidates = mockSearchRoots().flatMap { root in
            [
                root.appendingPathComponent("acp-mock-server/start.sh"),
                root.appendingPathComponent("../acp-mock-server/start.sh")
            ]
        }

        if let candidate = candidates.first(where: { fileManager.fileExists(atPath: $0.standardizedFileURL.path) }) {
            return candidate.standardizedFileURL
        }

        throw MockAcpRuntimeError.missingStartScript
    }

    private func mockSearchRoots() -> [URL] {
        var roots = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        ]
        var cursor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<6 {
            cursor.deleteLastPathComponent()
            roots.append(cursor)
        }
        return roots
    }

    private func defaultStatePath() -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".level5-build", isDirectory: true)
        return directory.appendingPathComponent("acp-mock-state.json").path
    }
}

private enum MockAcpRuntimeError: Error {
    case cancelled
    case missingStartScript
    case missingSessionId
    case notStarted
    case processExited
    case rpc(String)
    case timeout(String)
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }
}
