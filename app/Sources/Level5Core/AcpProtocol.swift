import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    public static func object(_ pairs: (String, JSONValue?)...) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs.compactMap { key, value in value.map { (key, $0) } }))
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

public enum AcpRpcID: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum AcpMethod {
    public static let initialize = "initialize"
    public static let authenticate = "authenticate"
    public static let logout = "logout"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionResume = "session/resume"
    public static let sessionClose = "session/close"
    public static let sessionList = "session/list"
    public static let sessionDelete = "session/delete"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionUpdate = "session/update"
    public static let sessionRequestPermission = "session/request_permission"
    public static let setMode = "session/set_mode"
    public static let setConfigOption = "session/set_config_option"
}

public struct AcpClientInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct AcpInitializeParams: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var clientInfo: AcpClientInfo
    public var clientCapabilities: [String: JSONValue]
    public var extra: [String: JSONValue]

    public init(
        protocolVersion: Int = 1,
        clientInfo: AcpClientInfo,
        clientCapabilities: [String: JSONValue] = [:],
        extra: [String: JSONValue] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        protocolVersion = try keyed.decode(Int.self, forKey: "protocolVersion")
        clientInfo = try keyed.decode(AcpClientInfo.self, forKey: "clientInfo")
        clientCapabilities = (try? keyed.decode([String: JSONValue].self, forKey: "clientCapabilities")) ?? [:]
        extra = keyed.decodeUnknown(excluding: ["protocolVersion", "clientInfo", "clientCapabilities"])
    }

    public func encode(to encoder: Encoder) throws {
        var keyed = encoder.container(keyedBy: DynamicCodingKey.self)
        try keyed.encode(protocolVersion, forKey: "protocolVersion")
        try keyed.encode(clientInfo, forKey: "clientInfo")
        try keyed.encode(clientCapabilities, forKey: "clientCapabilities")
        try keyed.encodeExtra(extra, excluding: ["protocolVersion", "clientInfo", "clientCapabilities"])
    }
}

public struct AcpInitializeResult: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var agentCapabilities: [String: JSONValue]
    public var agentInfo: AcpClientInfo?
    public var authMethods: [JSONValue]?
    public var extra: [String: JSONValue]

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        protocolVersion = try keyed.decode(Int.self, forKey: "protocolVersion")
        agentCapabilities = (try? keyed.decode([String: JSONValue].self, forKey: "agentCapabilities")) ?? [:]
        agentInfo = try? keyed.decode(AcpClientInfo.self, forKey: "agentInfo")
        authMethods = try? keyed.decode([JSONValue].self, forKey: "authMethods")
        extra = keyed.decodeUnknown(excluding: ["protocolVersion", "agentCapabilities", "agentInfo", "authMethods"])
    }
}

public struct AcpSessionParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var extra: [String: JSONValue]

    public init(sessionId: String, extra: [String: JSONValue] = [:]) {
        self.sessionId = sessionId
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        sessionId = try keyed.decode(String.self, forKey: "sessionId")
        extra = keyed.decodeUnknown(excluding: ["sessionId"])
    }

    public func encode(to encoder: Encoder) throws {
        var keyed = encoder.container(keyedBy: DynamicCodingKey.self)
        try keyed.encode(sessionId, forKey: "sessionId")
        try keyed.encodeExtra(extra, excluding: ["sessionId"])
    }
}

public struct AcpNewSessionParams: Codable, Equatable, Sendable {
    public var cwd: String
    public var additionalDirectories: [String]
    public var mcpServers: [JSONValue]
    public var extra: [String: JSONValue]

    public init(cwd: String, additionalDirectories: [String] = [], mcpServers: [JSONValue] = [], extra: [String: JSONValue] = [:]) {
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.extra = extra
    }
}

public struct AcpSessionResult: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var modes: JSONValue?
    public var configOptions: [JSONValue]
    public var extra: [String: JSONValue]

    public init(
        sessionId: String? = nil,
        modes: JSONValue? = nil,
        configOptions: [JSONValue] = [],
        extra: [String: JSONValue] = [:]
    ) {
        self.sessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        sessionId = try? keyed.decode(String.self, forKey: "sessionId")
        modes = try? keyed.decode(JSONValue.self, forKey: "modes")
        configOptions = (try? keyed.decode([JSONValue].self, forKey: "configOptions")) ?? []
        extra = keyed.decodeUnknown(excluding: ["sessionId", "modes", "configOptions"])
    }
}

public struct AcpSessionListResult: Codable, Equatable, Sendable {
    public var sessions: [AcpSessionSummary]
    public var nextCursor: String?
    public var extra: [String: JSONValue]

    public init(
        sessions: [AcpSessionSummary] = [],
        nextCursor: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        sessions = (try? keyed.decode([AcpSessionSummary].self, forKey: "sessions")) ?? []
        nextCursor = try? keyed.decode(String.self, forKey: "nextCursor")
        extra = keyed.decodeUnknown(excluding: ["sessions", "nextCursor"])
    }
}

public struct AcpSessionSummary: Codable, Equatable, Sendable {
    public var sessionId: String
    public var cwd: String?
    public var additionalDirectories: [String]
    public var title: String?
    public var updatedAt: String?
    public var extra: [String: JSONValue]

    public init(
        sessionId: String,
        cwd: String? = nil,
        additionalDirectories: [String] = [],
        title: String? = nil,
        updatedAt: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.title = title
        self.updatedAt = updatedAt
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        sessionId = try keyed.decode(String.self, forKey: "sessionId")
        cwd = try? keyed.decode(String.self, forKey: "cwd")
        additionalDirectories = (try? keyed.decode([String].self, forKey: "additionalDirectories")) ?? []
        title = try? keyed.decode(String.self, forKey: "title")
        updatedAt = try? keyed.decode(String.self, forKey: "updatedAt")
        extra = keyed.decodeUnknown(excluding: ["sessionId", "cwd", "additionalDirectories", "title", "updatedAt"])
    }

    public func encode(to encoder: Encoder) throws {
        var keyed = encoder.container(keyedBy: DynamicCodingKey.self)
        try keyed.encode(sessionId, forKey: "sessionId")
        try keyed.encodeIfPresent(cwd, forKey: DynamicCodingKey(stringValue: "cwd"))
        try keyed.encode(additionalDirectories, forKey: "additionalDirectories")
        try keyed.encodeIfPresent(title, forKey: DynamicCodingKey(stringValue: "title"))
        try keyed.encodeIfPresent(updatedAt, forKey: DynamicCodingKey(stringValue: "updatedAt"))
        try keyed.encodeExtra(extra, excluding: ["sessionId", "cwd", "additionalDirectories", "title", "updatedAt"])
    }
}

public struct AcpPromptParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var prompt: [JSONValue]
    public var extra: [String: JSONValue]

    public init(sessionId: String, prompt: [JSONValue], extra: [String: JSONValue] = [:]) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.extra = extra
    }
}

public struct AcpPromptResult: Codable, Equatable, Sendable {
    public var stopReason: String
    public var extra: [String: JSONValue]

    public init(stopReason: String, extra: [String: JSONValue] = [:]) {
        self.stopReason = stopReason
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        stopReason = try keyed.decode(String.self, forKey: "stopReason")
        extra = keyed.decodeUnknown(excluding: ["stopReason"])
    }
}

public struct AcpSessionUpdate: Codable, Equatable, Sendable {
    public var sessionId: String
    public var update: JSONValue
    public var extra: [String: JSONValue]

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        sessionId = try keyed.decode(String.self, forKey: "sessionId")
        update = (try? keyed.decode(JSONValue.self, forKey: "update")) ?? .object([:])
        extra = keyed.decodeUnknown(excluding: ["sessionId", "update"])
    }
}

public enum AcpProtocolCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func encodeJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try decoder.decode(JSONValue.self, from: encoder.encode(value))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try decoder.decode(type, from: encoder.encode(value))
    }
}

public struct DynamicCodingKey: CodingKey, Hashable, Sendable, ExpressibleByStringLiteral {
    public var stringValue: String
    public var intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    public init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    public init(stringLiteral value: String) {
        self.init(stringValue: value)
    }
}

private extension KeyedDecodingContainer where Key == DynamicCodingKey {
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T {
        try decode(type, forKey: DynamicCodingKey(stringValue: key))
    }

    func decodeUnknown(excluding knownKeys: Set<String>) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: allKeys.compactMap { key in
            guard !knownKeys.contains(key.stringValue) else { return nil }
            return (try? decode(JSONValue.self, forKey: key)).map { (key.stringValue, $0) }
        })
    }
}

private extension KeyedEncodingContainer where Key == DynamicCodingKey {
    mutating func encode<T: Encodable>(_ value: T, forKey key: String) throws {
        try encode(value, forKey: DynamicCodingKey(stringValue: key))
    }

    mutating func encodeExtra(_ extra: [String: JSONValue], excluding knownKeys: Set<String>) throws {
        for (key, value) in extra where !knownKeys.contains(key) {
            try encode(value, forKey: key)
        }
    }
}
