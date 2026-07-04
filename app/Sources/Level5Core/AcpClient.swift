import Foundation

public struct AcpClient: Sendable {
    public let transport: AcpJsonRpcTransport

    public init(transport: AcpJsonRpcTransport) {
        self.transport = transport
    }

    public var events: AsyncStream<AcpEvent> {
        transport.events
    }

    public func initialize(_ params: AcpInitializeParams) async throws -> AcpInitializeResult {
        try await request(AcpMethod.initialize, params: params, as: AcpInitializeResult.self)
    }

    public func listSessions(cwd: String? = nil, cursor: String? = nil) async throws -> AcpSessionListResult {
        var params: [String: JSONValue] = [:]
        if let cwd { params["cwd"] = .string(cwd) }
        if let cursor { params["cursor"] = .string(cursor) }
        return try await request(AcpMethod.sessionList, params: .object(params), as: AcpSessionListResult.self)
    }

    public func newSession(_ params: AcpNewSessionParams) async throws -> AcpSessionResult {
        try await request(AcpMethod.sessionNew, params: params, as: AcpSessionResult.self)
    }

    public func loadSession(_ params: AcpSessionParams) async throws -> AcpSessionResult {
        try await request(AcpMethod.sessionLoad, params: params, as: AcpSessionResult.self)
    }

    public func resumeSession(_ params: AcpSessionParams) async throws -> AcpSessionResult {
        try await request(AcpMethod.sessionResume, params: params, as: AcpSessionResult.self)
    }

    public func closeSession(_ params: AcpSessionParams) async throws {
        _ = try await request(AcpMethod.sessionClose, params: params, as: JSONValue.self)
    }

    public func deleteSession(_ params: AcpSessionParams) async throws {
        _ = try await request(AcpMethod.sessionDelete, params: params, as: JSONValue.self)
    }

    public func prompt(_ params: AcpPromptParams) async throws -> AcpPromptResult {
        try await request(AcpMethod.sessionPrompt, params: params, as: AcpPromptResult.self)
    }

    public func cancel(sessionId: String) async throws {
        try await transport.notify(method: AcpMethod.sessionCancel, params: .object(["sessionId": .string(sessionId)]))
    }

    public func extensionRequest(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        try await transport.request(method: method, params: params)
    }

    public func respond(id: AcpRpcID, result: JSONValue) async throws {
        try await transport.respond(id: id, result: result)
    }

    public func respondError(id: AcpRpcID, code: Int, message: String, data: JSONValue? = nil) async throws {
        try await transport.respondError(id: id, error: AcpRpcError(code: code, message: message, data: data))
    }

    private func request<T: Decodable>(_ method: String, params: some Encodable, as type: T.Type) async throws -> T {
        let encoded = try AcpProtocolCoding.encodeJSONValue(params)
        let jsonParams: JSONValue? = encoded
        return try await request(method, params: jsonParams, as: type)
    }

    private func request<T: Decodable>(_ method: String, params: JSONValue?, as type: T.Type) async throws -> T {
        return try AcpProtocolCoding.decode(type, from: try await transport.request(method: method, params: params))
    }
}
