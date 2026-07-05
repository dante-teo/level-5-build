import Foundation
import Level5Core
import Network

enum AgentBackendKind: Equatable, Hashable, Sendable {
    case acpMock
    case devin
    case unavailable
}

extension AgentBackendKind {
    /// The `backend` column value used in `Level5Core.SessionPersistenceStore`.
    var persistedIdentifier: String {
        switch self {
        case .acpMock: "mock"
        case .devin: "devin"
        case .unavailable: "unavailable"
        }
    }
}

struct AgentBackendSelector: Sendable {
    var environment: [String: String]
    var allowsMockBackend: Bool
    var homeDirectoryPath: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsMockBackend: Bool = AgentBackendSelector.defaultAllowsMockBackend,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.environment = environment
        self.allowsMockBackend = allowsMockBackend
        self.homeDirectoryPath = homeDirectoryPath
    }

    var selectedBackend: AgentBackendKind {
        if allowsMockBackend, environment["LEVEL5_USE_ACP_MOCK"] == "1" {
            return .acpMock
        }
        if DevinRuntime.isAvailable(environment: environment, homeDirectoryPath: homeDirectoryPath) {
            return .devin
        }
        return .unavailable
    }

    /// User-facing explanation for why no backend is available. `nil` when a
    /// backend was successfully selected.
    var unavailableReason: String? {
        guard selectedBackend == .unavailable else { return nil }
        return DevinRuntime.missingCliMessage
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
    func newSession(cwd: String) async throws -> AcpSessionResult
    func loadSession(sessionId: String, cwd: String?) async throws -> AcpSessionResult
    func deleteSession(sessionId: String) async throws
    func listModelOptions(sessionId: String?) async throws -> (options: [ComposerModelOption], currentModelId: String?)
    func listSlashCommands(sessionId: String?) async throws -> [ComposerCommand]
    func setModel(sessionId: String, modelId: String) async throws -> AcpSessionResult
    func prompt(sessionId: String, blocks: [JSONValue]) async throws -> AcpPromptResult
    func cancel(sessionId: String) async throws
    func respondToPermissionRequest(_ response: PermissionResponse) async throws
    func cancelPermissionRequest(_ requestId: AcpRpcID) async throws
    func terminate()
}

/// Shared ACP request plumbing for `AgentSessionClient` implementations that
/// speak to their backing agent purely through an `AcpClient`. Conformers
/// need to supply `client` and `terminate()`; this extension does not
/// default `listModelOptions`/`listSlashCommands` because backends differ
/// significantly in how (or whether) discovery works — e.g. real Devin has
/// no request/response API for either and must throw rather than delegate
/// (see `DevinAgentSessionClient`).
protocol AcpClientBackedSessionClient: AgentSessionClient {
    var client: AcpClient { get }
}

extension AcpClientBackedSessionClient {
    var events: AsyncStream<AcpEvent> {
        client.events
    }

    func initialize() async throws {
        _ = try await client.initialize(.init(
            clientInfo: .init(name: "Level5 Build", version: "0.0.0")
        ))
    }

    func newSession(cwd: String) async throws -> AcpSessionResult {
        try await client.newSession(.init(cwd: cwd))
    }

    func loadSession(sessionId: String, cwd: String?) async throws -> AcpSessionResult {
        // Real Devin's `session/load`, like `session/new`, requires
        // `mcpServers` in params — without it the call fails outright with
        // a deserialization error, silently breaking every existing-session
        // reconnect (mock is not strict here so this is harmless there).
        var extra: [String: JSONValue] = ["mcpServers": .array([])]
        if let cwd { extra["cwd"] = .string(cwd) }
        return try await client.loadSession(.init(sessionId: sessionId, extra: extra))
    }

    func deleteSession(sessionId: String) async throws {
        try await client.deleteSession(.init(sessionId: sessionId))
    }

    func setModel(sessionId: String, modelId: String) async throws -> AcpSessionResult {
        try await client.setConfigOption(sessionId: sessionId, configId: "model", value: modelId)
    }

    func prompt(sessionId: String, blocks: [JSONValue]) async throws -> AcpPromptResult {
        try await client.prompt(.init(sessionId: sessionId, prompt: blocks))
    }

    func cancel(sessionId: String) async throws {
        try await client.cancel(sessionId: sessionId)
    }

    func respondToPermissionRequest(_ response: PermissionResponse) async throws {
        try await client.respond(id: response.requestId, result: [
            "outcome": [
                "outcome": "selected",
                "optionId": .string(response.optionId)
            ]
        ])
    }

    func cancelPermissionRequest(_ requestId: AcpRpcID) async throws {
        try await client.respond(id: requestId, result: [
            "outcome": [
                "outcome": "cancelled"
            ]
        ])
    }
}

final class AcpProcessAgentSessionClient: AcpClientBackedSessionClient, @unchecked Sendable {
    private let process: AcpProcessTransport
    let client: AcpClient

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

    func listModelOptions(sessionId: String?) async throws -> (options: [ComposerModelOption], currentModelId: String?) {
        try await modelOptions(client: client, sessionId: sessionId)
    }

    func listSlashCommands(sessionId: String?) async throws -> [ComposerCommand] {
        try await slashCommands(client: client, sessionId: sessionId)
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
    case missingDevinExecutable
    /// Thrown by discovery methods (`listModelOptions`/`listSlashCommands`)
    /// that a backend has no request/response API for. Callers use `try?`
    /// and skip updating state on failure, so this must be thrown rather
    /// than returning an empty success — an empty *success* would stomp
    /// over state a backend already populated another way (e.g. Devin's
    /// live `session/update` notifications).
    case discoveryUnsupported
}

/// Spawns and speaks ACP to a real `devin acp` process for a single project
/// directory. One instance exists per project `cwd` so that projects can run
/// fully concurrent, isolated Devin sessions (see `AgentSessionModel`).
final class DevinAgentSessionClient: AcpClientBackedSessionClient, @unchecked Sendable {
    private let process: AcpProcessTransport
    let client: AcpClient

    let spawnedCwd: String
    let spawnedPermissionMode: String

    init(
        cwd: String,
        approvalMode: ApprovalMode,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestTimeout: Duration = .seconds(30)
    ) throws {
        guard let executableURL = DevinRuntime.resolveExecutableURL(environment: environment) else {
            throw AgentBackendError.missingDevinExecutable
        }
        let permissionMode = DevinRuntime.permissionMode(for: approvalMode)
        spawnedCwd = RecentProjectStore.normalizedPath(cwd)
        spawnedPermissionMode = permissionMode

        process = AcpProcessTransport(
            executableURL: executableURL,
            arguments: ["--permission-mode", permissionMode, "acp"],
            environment: environment,
            currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true),
            eventBufferLimit: 500,
            requestTimeout: requestTimeout
        )
        try process.start()
        client = AcpClient(transport: process.transport)
    }

    /// Real Devin has no request/response API for listing models or slash
    /// commands (including skills, which arrive as slash commands too)
    /// outside of a session; both arrive as `session/update` notifications
    /// (`config_option_update`, `available_commands_update`) once a session
    /// exists, which `AgentSessionModel` applies live. These must throw
    /// rather than return an empty list/tuple, or callers using `try?`
    /// would treat "unsupported" as a successful empty result and wipe out
    /// whatever the live notifications already populated.
    func listModelOptions(sessionId: String?) async throws -> (options: [ComposerModelOption], currentModelId: String?) {
        throw AgentBackendError.discoveryUnsupported
    }

    func listSlashCommands(sessionId: String?) async throws -> [ComposerCommand] {
        throw AgentBackendError.discoveryUnsupported
    }

    func terminate() {
        process.terminate()
    }
}

final class AcpTcpAgentSessionClient: AcpClientBackedSessionClient, @unchecked Sendable {
    private let socket: AcpTcpLineTransport
    let client: AcpClient

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

    func listModelOptions(sessionId: String?) async throws -> (options: [ComposerModelOption], currentModelId: String?) {
        try await modelOptions(client: client, sessionId: sessionId)
    }

    func listSlashCommands(sessionId: String?) async throws -> [ComposerCommand] {
        try await slashCommands(client: client, sessionId: sessionId)
    }

    func terminate() {
        socket.cancel()
    }
}

private func modelOptions(client: AcpClient, sessionId: String?) async throws -> (options: [ComposerModelOption], currentModelId: String?) {
    var params: [String: JSONValue] = [:]
    if let sessionId {
        params["sessionId"] = .string(sessionId)
    }
    let result = try await client.extensionRequest(method: "_mock/list_models", params: .object(params))
    guard let object = result.objectValue else {
        return ([], nil)
    }
    let options = object["models"]?.arrayValue?.compactMap { value -> ComposerModelOption? in
        guard let object = value.objectValue else { return nil }
        guard let id = object["id"]?.stringValue ?? object["value"]?.stringValue else { return nil }
        return ComposerModelOption(
            id: id,
            label: object["name"]?.stringValue,
            modelDescription: object["description"]?.stringValue
        )
    } ?? []
    return (options, object["currentModel"]?.stringValue)
}

private func slashCommands(client: AcpClient, sessionId: String?) async throws -> [ComposerCommand] {
    var params: [String: JSONValue] = [:]
    if let sessionId {
        params["sessionId"] = .string(sessionId)
    }
    let result = try await client.extensionRequest(method: "_mock/list_slash_commands", params: .object(params))
    let values = result.objectValue?["availableCommands"]?.arrayValue ?? result.objectValue?["commands"]?.arrayValue ?? []
    return parseComposerCommands(values)
}

/// Shared parsing for the `availableCommands`/`commands` shape used both by
/// the mock server's `_mock/list_slash_commands` extension response and real
/// Devin's `available_commands_update` session/update notification payload.
func parseComposerCommands(_ values: [JSONValue]) -> [ComposerCommand] {
    values.compactMap { value -> ComposerCommand? in
        guard let object = value.objectValue else { return nil }
        guard let name = object["name"]?.stringValue else { return nil }
        let input = object["input"]?.objectValue
        return ComposerCommand(
            name: name,
            displayName: object["displayName"]?.stringValue ?? object["title"]?.stringValue,
            commandDescription: object["description"]?.stringValue,
            inputHint: input?["hint"]?.stringValue
        )
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
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
