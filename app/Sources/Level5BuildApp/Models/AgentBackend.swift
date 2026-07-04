import Foundation
import Level5Core
import Network

enum AgentBackendKind: Equatable, Sendable {
    case acpMock
    case unavailable
}

struct AgentBackendSelector: Sendable {
    var environment: [String: String]
    var allowsMockBackend: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsMockBackend: Bool = AgentBackendSelector.defaultAllowsMockBackend
    ) {
        self.environment = environment
        self.allowsMockBackend = allowsMockBackend
    }

    var selectedBackend: AgentBackendKind {
        if allowsMockBackend, environment["LEVEL5_USE_ACP_MOCK"] == "1" {
            return .acpMock
        }
        return .unavailable
    }

    static var defaultAllowsMockBackend: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

protocol AgentSessionClient: Sendable {
    var events: AsyncStream<AcpEvent> { get }

    func initialize() async throws
    func listSessions(cursor: String?) async throws -> AcpSessionListResult
    func newSession(cwd: String) async throws -> AcpSessionResult
    func loadSession(sessionId: String, cwd: String?) async throws -> AcpSessionResult
    func deleteSession(sessionId: String) async throws
    func prompt(sessionId: String, text: String) async throws -> AcpPromptResult
    func respondToPermissionRequest(id: AcpRpcID, allow: Bool) async throws
    func terminate()
}

final class AcpProcessAgentSessionClient: AgentSessionClient, @unchecked Sendable {
    private let process: AcpProcessTransport
    private let client: AcpClient

    var events: AsyncStream<AcpEvent> {
        client.events
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestTimeout: Duration = .seconds(30)
    ) throws {
        let startScript = try Self.resolveMockStartScript(environment: environment)
        let mockRoot = startScript.deletingLastPathComponent()
        let executableURL: URL
        let arguments: [String]

        if
            let nodePath = environment["LEVEL5_NODE_PATH"],
            !nodePath.isEmpty,
            FileManager.default.fileExists(atPath: mockRoot.appendingPathComponent("dist/src/index.js").path)
        {
            executableURL = URL(fileURLWithPath: nodePath)
            arguments = [mockRoot.appendingPathComponent("dist/src/index.js").path]
        } else {
            executableURL = URL(fileURLWithPath: "/bin/bash")
            arguments = [startScript.path]
        }

        process = AcpProcessTransport(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment.merging([
                "ACP_MOCK_LOG": environment["ACP_MOCK_LOG"] ?? "silent",
                "ACP_MOCK_STATE_PATH": environment["ACP_MOCK_STATE_PATH"] ?? Self.defaultStatePath()
            ]) { _, new in new },
            currentDirectoryURL: mockRoot,
            eventBufferLimit: 500,
            requestTimeout: requestTimeout
        )
        try process.start()
        client = AcpClient(transport: process.transport)
    }

    func initialize() async throws {
        _ = try await client.initialize(.init(
            clientInfo: .init(name: "Level5 Build", version: "0.0.0")
        ))
    }

    func listSessions(cursor: String?) async throws -> AcpSessionListResult {
        try await client.listSessions(cursor: cursor)
    }

    func newSession(cwd: String) async throws -> AcpSessionResult {
        try await client.newSession(.init(cwd: cwd))
    }

    func loadSession(sessionId: String, cwd: String?) async throws -> AcpSessionResult {
        try await client.loadSession(.init(
            sessionId: sessionId,
            extra: cwd.map { ["cwd": .string($0)] } ?? [:]
        ))
    }

    func deleteSession(sessionId: String) async throws {
        try await client.deleteSession(.init(sessionId: sessionId))
    }

    func prompt(sessionId: String, text: String) async throws -> AcpPromptResult {
        try await client.prompt(.init(sessionId: sessionId, prompt: [
            [
                "type": "text",
                "text": .string(text)
            ]
        ]))
    }

    func respondToPermissionRequest(id: AcpRpcID, allow: Bool) async throws {
        try await client.respond(id: id, result: [
            "outcome": [
                "optionId": .string(allow ? "allow-once" : "reject-once")
            ]
        ])
    }

    func terminate() {
        process.terminate()
    }

    private static func resolveMockStartScript(environment: [String: String]) throws -> URL {
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

        throw AgentBackendError.missingMockStartScript
    }

    private static func mockSearchRoots() -> [URL] {
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

    private static func defaultStatePath() -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".level5-build", isDirectory: true)
        return directory.appendingPathComponent("acp-mock-state.json").path
    }
}

enum AgentBackendError: Error, Equatable {
    case missingMockStartScript
}

final class AcpTcpAgentSessionClient: AgentSessionClient, @unchecked Sendable {
    private let socket: AcpTcpLineTransport
    private let client: AcpClient

    var events: AsyncStream<AcpEvent> {
        client.events
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestTimeout: Duration = .seconds(8)
    ) {
        let host = environment["LEVEL5_ACP_MOCK_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["LEVEL5_ACP_MOCK_PORT"] ?? "58945") ?? 58945
        socket = AcpTcpLineTransport(host: host, port: port, requestTimeout: requestTimeout, connectTimeout: .seconds(3))
        client = AcpClient(transport: socket.transport)
        socket.start()
    }

    func initialize() async throws {
        try await socket.waitUntilReady()
        _ = try await client.initialize(.init(
            clientInfo: .init(name: "Level5 Build", version: "0.0.0")
        ))
    }

    func listSessions(cursor: String?) async throws -> AcpSessionListResult {
        try await client.listSessions(cursor: cursor)
    }

    func newSession(cwd: String) async throws -> AcpSessionResult {
        try await client.newSession(.init(cwd: cwd))
    }

    func loadSession(sessionId: String, cwd: String?) async throws -> AcpSessionResult {
        try await client.loadSession(.init(
            sessionId: sessionId,
            extra: cwd.map { ["cwd": .string($0)] } ?? [:]
        ))
    }

    func deleteSession(sessionId: String) async throws {
        try await client.deleteSession(.init(sessionId: sessionId))
    }

    func prompt(sessionId: String, text: String) async throws -> AcpPromptResult {
        try await client.prompt(.init(sessionId: sessionId, prompt: [
            [
                "type": "text",
                "text": .string(text)
            ]
        ]))
    }

    func respondToPermissionRequest(id: AcpRpcID, allow: Bool) async throws {
        try await client.respond(id: id, result: [
            "outcome": [
                "optionId": .string(allow ? "allow-once" : "reject-once")
            ]
        ])
    }

    func terminate() {
        socket.cancel()
    }
}

private final class AcpTcpLineTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.anvia.level5.acp-mock-tcp")
    private var buffer = Data()
    private var isReady = false
    private var startupFailure: Error?
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var connectTimeoutTask: Task<Void, Never>?

    let transport: AcpJsonRpcTransport

    init(host: String, port: UInt16, requestTimeout: Duration, connectTimeout: Duration) {
        let tcpPort = NWEndpoint.Port(rawValue: port) ?? 58945
        let connection = NWConnection(host: NWEndpoint.Host(host), port: tcpPort, using: .tcp)
        self.connection = connection
        transport = AcpJsonRpcTransport(
            eventBufferLimit: 500,
            requestTimeout: requestTimeout
        ) { line in
            let data = Data((line + "\n").utf8)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: AcpTransportError.failed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
        connectTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: connectTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let error = AcpTransportError.failed("Timed out connecting to ACP mock server at \(host):\(port). Start it with ./script/run_mock_app.sh.")
            self.queue.async {
                self.failStartup(error)
            }
            await self.transport.failAll(error)
            self.connection.cancel()
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.completeStartup()
            case .waiting(let error):
                let transportError = AcpTransportError.failed("Mock ACP TCP connection waiting: \(error.localizedDescription)")
                self.failStartup(transportError)
                Task {
                    await self.transport.failAll(transportError)
                }
            case .failed(let error):
                let transportError = AcpTransportError.failed(error.localizedDescription)
                self.failStartup(transportError)
                Task {
                    await self.transport.failAll(transportError)
                }
            case .cancelled:
                self.failStartup(AcpTransportError.processExited(0))
                Task {
                    await self.transport.emitProcessExit(status: 0, reason: "tcp cancelled")
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.isReady {
                    continuation.resume()
                } else if let startupFailure = self.startupFailure {
                    continuation.resume(throwing: startupFailure)
                } else {
                    self.readyContinuations.append(continuation)
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func completeStartup() {
        guard !isReady else { return }
        isReady = true
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        let continuations = readyContinuations
        readyContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func failStartup(_ error: Error) {
        guard startupFailure == nil, !isReady else { return }
        startupFailure = error
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        let continuations = readyContinuations
        readyContinuations.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if let error {
                Task {
                    await self.transport.failAll(AcpTransportError.failed(error.localizedDescription))
                }
                return
            }
            if isComplete {
                Task {
                    await self.transport.emitProcessExit(status: 0, reason: "tcp closed")
                }
                return
            }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[..<index]
            buffer.removeSubrange(...index)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            Task {
                await transport.handleLine(line)
            }
        }
    }
}
