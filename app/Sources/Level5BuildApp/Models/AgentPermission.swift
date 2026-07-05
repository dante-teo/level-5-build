import Foundation
import Level5Core

enum ApprovalMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case ask = "ask"
    case approveForMe = "approve_for_me"
    case fullAccess = "full_access"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask:
            "Ask for approval"
        case .approveForMe:
            "Approve for me"
        case .fullAccess:
            "Full access"
        }
    }
}

struct PermissionResponse: Equatable, Sendable {
    var requestId: AcpRpcID
    var optionId: String
    var localInstructionText: String?
}

struct PermissionRequest: Identifiable, Equatable, Sendable {
    var id: String { requestId.descriptionKey }
    var requestId: AcpRpcID
    var sessionId: String
    var title: String
    var toolKind: String?
    var toolStatus: String?
    var detail: String?
    var rawInput: String?
    var options: [PermissionOption]

    static func parse(requestId: AcpRpcID, params: JSONValue?) -> PermissionRequest? {
        guard let object = params?.objectValue else { return nil }
        guard let sessionId = object["sessionId"]?.stringValue?.nonEmpty else { return nil }
        let toolCall = object["toolCall"]?.objectValue ?? [:]
        let title = toolCall["title"]?.stringValue?.nonEmpty
            ?? toolCall["kind"]?.stringValue?.nonEmpty
            ?? "Permission requested"

        return PermissionRequest(
            requestId: requestId,
            sessionId: sessionId,
            title: title,
            toolKind: toolCall["kind"]?.stringValue,
            toolStatus: toolCall["status"]?.stringValue,
            detail: Self.contentText(from: toolCall["content"]),
            rawInput: toolCall["rawInput"].flatMap(Self.prettyString),
            options: (object["options"]?.arrayValue ?? []).compactMap(PermissionOption.parse)
        )
    }

    var allowLikeOption: PermissionOption? {
        options.first(where: \.isAllowLike)
    }

    var rejectLikeOption: PermissionOption? {
        options.first(where: \.isRejectLike)
    }

    var automaticApprovalOption: PermissionOption? {
        allowLikeOption ?? options.first
    }

    var rejectInstructionOption: PermissionOption? {
        rejectLikeOption ?? options.last
    }

    private static func contentText(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        let chunks = value.arrayValue?.compactMap { item -> String? in
            let object = item.objectValue
            if let text = object?["text"]?.stringValue {
                return text
            }
            if let nested = object?["content"]?.objectValue {
                return nested["text"]?.stringValue
            }
            return nil
        } ?? []
        return chunks.joined(separator: "\n").nonEmpty ?? prettyString(value)
    }

    private static func prettyString(_ value: JSONValue) -> String? {
        if let string = value.stringValue {
            return string
        }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct PermissionOption: Identifiable, Equatable, Sendable {
    var id: String { optionId }
    var optionId: String
    var name: String
    var kind: String?

    static func parse(_ value: JSONValue) -> PermissionOption? {
        guard let object = value.objectValue else { return nil }
        guard let optionId = object["optionId"]?.stringValue?.nonEmpty else { return nil }
        return PermissionOption(
            optionId: optionId,
            name: object["name"]?.stringValue?.nonEmpty ?? optionId.readablePermissionLabel,
            kind: object["kind"]?.stringValue
        )
    }

    var isAllowLike: Bool {
        [kind, name, optionId].compactMap { $0 }.contains { value in
            let normalized = value.permissionNormalized
            return normalized.hasPrefix("allow") || normalized.contains("_allow")
        }
    }

    var isRejectLike: Bool {
        [kind, name, optionId].compactMap { $0 }.contains { value in
            let normalized = value.permissionNormalized
            return normalized.hasPrefix("reject") || normalized.contains("_reject")
        }
    }
}

struct ApprovalModePreferenceStore: Sendable {
    var load: @Sendable (AgentBackendKind) -> ApprovalMode
    var save: @Sendable (ApprovalMode, AgentBackendKind) -> Void

    static let userDefaults = ApprovalModePreferenceStore(
        load: { backendKind in
            let key = "approvalMode.\(backendKind.preferenceKeyComponent)"
            guard let rawValue = UserDefaults.standard.string(forKey: key) else { return .ask }
            return ApprovalMode(rawValue: rawValue) ?? .ask
        },
        save: { mode, backendKind in
            let key = "approvalMode.\(backendKind.preferenceKeyComponent)"
            UserDefaults.standard.set(mode.rawValue, forKey: key)
        }
    )

    static let ephemeral = ApprovalModePreferenceStore(load: { _ in .ask }, save: { _, _ in })
}

extension AcpRpcID {
    var descriptionKey: String {
        switch self {
        case let .string(value):
            "string:\(value)"
        case let .int(value):
            "int:\(value)"
        case .null:
            "null"
        }
    }
}

private extension AgentBackendKind {
    var preferenceKeyComponent: String {
        switch self {
        case .acpMock:
            "acpMock"
        case .devin:
            "devin"
        case .unavailable:
            "unavailable"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var permissionNormalized: String {
        lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    var readablePermissionLabel: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }
}
