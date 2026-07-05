import Foundation

/// Pure, testable helpers for locating and configuring the real Devin CLI
/// (`devin acp`) runtime. Kept free of process/session state so it can be
/// unit tested without spawning anything.
enum DevinRuntime {
    static let executableName = "devin"

    /// Directories checked in addition to `$PATH`, mirroring where the
    /// installer and common package managers place the `devin` binary.
    static func knownInstallDirectories(homeDirectoryPath: String) -> [String] {
        [
            "\(homeDirectoryPath)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
    }

    static func resolveExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let searchDirectories = pathDirectories + knownInstallDirectories(homeDirectoryPath: homeDirectoryPath)

        for directory in searchDirectories {
            guard !directory.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }

    static func isAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Bool {
        resolveExecutableURL(environment: environment, fileManager: fileManager, homeDirectoryPath: homeDirectoryPath) != nil
    }

    /// Maps the app's approval mode to a `devin --permission-mode` value.
    /// `bypass` is the documented alias for `dangerous`; both `ask` and
    /// `approveForMe` need the agent to actually pause and request
    /// permission, which only `normal` does.
    static func permissionMode(for approvalMode: ApprovalMode) -> String {
        switch approvalMode {
        case .ask, .approveForMe:
            "normal"
        case .fullAccess:
            "bypass"
        }
    }

    static let missingCliMessage =
        "Devin CLI not found. Install it from https://devin.ai/cli, run `devin auth login`, then restart Level5 Build."
}
