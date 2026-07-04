import Foundation

public struct AcpRpcError: Error, Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct AcpDiagnostic: Equatable, Sendable {
    public enum Level: String, Sendable {
        case debug
        case info
        case warning
        case error
    }

    public var level: Level
    public var message: String

    public init(level: Level, message: String) {
        self.level = level
        self.message = message
    }
}

public struct AcpProcessExit: Equatable, Sendable {
    public var status: Int32
    public var reason: String
}

public enum AcpEvent: Sendable {
    case notification(method: String, params: JSONValue?)
    case serverRequest(id: AcpRpcID, method: String, params: JSONValue?)
    case diagnostic(AcpDiagnostic)
    case activity(String)
    case stderr(String)
    case processExit(AcpProcessExit)
}

public enum AcpTransportError: Error, Equatable, Sendable {
    case failed(String)
    case invalidResponse(String)
    case requestTimedOut(AcpRpcID)
    case requestCancelled(AcpRpcID)
    case processExited(Int32)
}

public actor AcpJsonRpcTransport {
    public typealias WriteLine = @Sendable (String) async throws -> Void

    private struct Pending: Sendable {
        var continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>
    }

    public nonisolated let events: AsyncStream<AcpEvent>

    private let writeLine: WriteLine
    private let continuation: AsyncStream<AcpEvent>.Continuation
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let defaultTimeout: Duration
    private let maxLineBytes: Int
    private var nextRequestId = 1
    private var pending: [AcpRpcID: Pending] = [:]
    private var failed = false

    public init(
        eventBufferLimit: Int = 100,
        maxLineBytes: Int = 1_048_576,
        requestTimeout: Duration = .seconds(10),
        writeLine: @escaping WriteLine
    ) {
        var captured: AsyncStream<AcpEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(eventBufferLimit)) { continuation in
            captured = continuation
        }
        self.continuation = captured
        self.writeLine = writeLine
        self.defaultTimeout = requestTimeout
        self.maxLineBytes = maxLineBytes
    }

    deinit {
        continuation.finish()
    }

    public func request(method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
        let id = AcpRpcID.int(nextRequestId)
        nextRequestId += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task.detached { [defaultTimeout] in
                    let effectiveTimeout = timeout ?? defaultTimeout
                    try? await Task.sleep(for: effectiveTimeout)
                    await self.timeoutPending(id)
                }
                pending[id] = Pending(continuation: continuation, timeoutTask: timeoutTask)
                let line: String
                do {
                    line = try encodeLine(OutgoingMessage.request(id: id, method: method, params: params))
                } catch {
                    failPending(id, error: error)
                    return
                }
                let writeLine = writeLine
                Task.detached {
                    do {
                        try await writeLine(line)
                        await self.emitActivity("sent request \(method)")
                    } catch {
                        await self.failPending(id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelPending(id) }
        }
    }

    public func notify(method: String, params: JSONValue? = nil) async throws {
        try await writeLine(try encodeLine(OutgoingMessage.notification(method: method, params: params)))
        continuation.yield(.activity("sent notification \(method)"))
    }

    public func respond(id: AcpRpcID, result: JSONValue) async throws {
        try await writeLine(try encodeLine(OutgoingMessage.response(id: id, result: result)))
        continuation.yield(.activity("sent response \(id)"))
    }

    public func respondError(id: AcpRpcID, error: AcpRpcError) async throws {
        try await writeLine(try encodeLine(OutgoingMessage.error(id: id, error: error)))
        continuation.yield(.activity("sent error response \(id)"))
    }

    public func handleLine(_ line: String) {
        guard !failed else { return }
        guard line.utf8.count <= maxLineBytes else {
            let error = AcpTransportError.failed("ACP stdout line exceeded \(maxLineBytes) bytes")
            continuation.yield(.diagnostic(.init(level: .error, message: "ACP stdout line exceeded \(maxLineBytes) bytes")))
            failAll(error)
            return
        }
        guard let data = line.data(using: .utf8) else {
            continuation.yield(.diagnostic(.init(level: .error, message: "stdout line was not valid UTF-8")))
            return
        }
        do {
            let envelope = try decoder.decode(IncomingEnvelope.self, from: data)
            try handleEnvelope(envelope)
        } catch {
            continuation.yield(.diagnostic(.init(level: .error, message: "malformed JSON-RPC message: \(error)")))
        }
    }

    public func emitStderr(_ line: String) {
        continuation.yield(.stderr(line))
    }

    public func emitProcessExit(status: Int32, reason: String = "exit") {
        continuation.yield(.processExit(.init(status: status, reason: reason)))
        failAll(AcpTransportError.processExited(status))
    }

    public func failAll(_ error: Error) {
        failed = true
        let current = pending
        pending.removeAll()
        current.values.forEach { pending in
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        continuation.yield(.diagnostic(.init(level: .error, message: String(describing: error))))
    }

    private func handleEnvelope(_ envelope: IncomingEnvelope) throws {
        guard envelope.jsonrpc == "2.0" else {
            continuation.yield(.diagnostic(.init(level: .error, message: "invalid JSON-RPC version")))
            return
        }
        if let method = envelope.method, let id = envelope.id {
            continuation.yield(.serverRequest(id: id, method: method, params: envelope.params))
        } else if let method = envelope.method {
            continuation.yield(.notification(method: method, params: envelope.params))
        } else if let id = envelope.id, envelope.result != nil || envelope.error != nil {
            guard let pending = pending.removeValue(forKey: id) else {
                continuation.yield(.diagnostic(.init(level: .warning, message: "unexpected response id \(id)")))
                return
            }
            pending.timeoutTask.cancel()
            if let error = envelope.error {
                pending.continuation.resume(throwing: error)
            } else {
                pending.continuation.resume(returning: envelope.result ?? .null)
            }
        } else {
            continuation.yield(.diagnostic(.init(level: .error, message: "invalid JSON-RPC envelope")))
        }
    }

    private func timeoutPending(_ id: AcpRpcID) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: AcpTransportError.requestTimedOut(id))
    }

    private func cancelPending(_ id: AcpRpcID) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: AcpTransportError.requestCancelled(id))
    }

    private func failPending(_ id: AcpRpcID, error: Error) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func emitActivity(_ message: String) {
        continuation.yield(.activity(message))
    }

    private func encodeLine(_ message: OutgoingMessage) throws -> String {
        String(decoding: try encoder.encode(message), as: UTF8.self)
    }
}

private struct IncomingEnvelope: Decodable {
    var jsonrpc: String
    var id: AcpRpcID?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: AcpRpcError?
}

private enum OutgoingMessage: Encodable {
    case request(id: AcpRpcID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: AcpRpcID, result: JSONValue)
    case error(id: AcpRpcID, error: AcpRpcError)

    func encode(to encoder: Encoder) throws {
        var keyed = encoder.container(keyedBy: DynamicCodingKey.self)
        try keyed.encode("2.0", forKey: "jsonrpc")
        switch self {
        case let .request(id, method, params):
            try keyed.encode(id, forKey: "id")
            try keyed.encode(method, forKey: "method")
            if let params { try keyed.encode(params, forKey: "params") }
        case let .notification(method, params):
            try keyed.encode(method, forKey: "method")
            if let params { try keyed.encode(params, forKey: "params") }
        case let .response(id, result):
            try keyed.encode(id, forKey: "id")
            try keyed.encode(result, forKey: "result")
        case let .error(id, error):
            try keyed.encode(id, forKey: "id")
            try keyed.encode(error, forKey: "error")
        }
    }
}
