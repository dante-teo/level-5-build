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

    /// Unlike every other request, `session/prompt` doesn't resolve until
    /// the *entire* agent turn completes — which, for a real coding turn
    /// with tool calls, routinely takes far longer than the short
    /// (10-30s) default request timeout meant for quick RPCs like
    /// `initialize`/`session/new`. Applying that default here caused the
    /// request to time out and get reported as "Prompt failed" while the
    /// agent was still legitimately working; the real reply would still
    /// stream in via `session/update` notifications and even the eventual
    /// `session/prompt` response would still arrive, just too late to
    /// match a still-pending request — logged as an "unexpected response
    /// id" and silently dropped. Detecting a genuinely stuck turn is
    /// already `AgentSessionModel`'s idle-activity watchdog's job (it
    /// resets on every inbound event, not on a fixed wall-clock budget),
    /// so this uses a generous fixed upper bound purely as a last-resort
    /// safety net against a leaked continuation, not as the real
    /// timeout mechanism.
    public func prompt(_ params: AcpPromptParams) async throws -> AcpPromptResult {
        try await request(AcpMethod.sessionPrompt, params: params, as: AcpPromptResult.self, timeout: .seconds(21_600))
    }

    public func cancel(sessionId: String) async throws {
        try await transport.notify(method: AcpMethod.sessionCancel, params: .object(["sessionId": .string(sessionId)]))
    }

    public func setConfigOption(sessionId: String, configId: String, value: String) async throws -> AcpSessionResult {
        try await request(AcpMethod.setConfigOption, params: JSONValue.object([
            "sessionId": .string(sessionId),
            "configId": .string(configId),
            "value": .string(value)
        ]), as: AcpSessionResult.self)
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

    private func request<T: Decodable>(_ method: String, params: some Encodable, as type: T.Type, timeout: Duration? = nil) async throws -> T {
        let encoded = try AcpProtocolCoding.encodeJSONValue(params)
        let jsonParams: JSONValue? = encoded
        return try await request(method, params: jsonParams, as: type, timeout: timeout)
    }

    private func request<T: Decodable>(_ method: String, params: JSONValue?, as type: T.Type, timeout: Duration? = nil) async throws -> T {
        return try AcpProtocolCoding.decode(type, from: try await transport.request(method: method, params: params, timeout: timeout))
    }
}
