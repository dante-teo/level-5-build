import Foundation
import Testing
@testable import Level5BuildApp

@Suite("Devin runtime")
struct DevinRuntimeTests {
    @Test("Resolves the executable from a PATH directory")
    func resolvesFromPath() throws {
        let (binDirectory, cleanup) = try Self.makeExecutable(named: "devin")
        defer { cleanup() }

        let environment = ["PATH": binDirectory.path]
        let resolved = DevinRuntime.resolveExecutableURL(environment: environment, homeDirectoryPath: "/nonexistent-home")

        #expect(resolved?.path == binDirectory.appendingPathComponent("devin").path)
        #expect(DevinRuntime.isAvailable(environment: environment, homeDirectoryPath: "/nonexistent-home"))
    }

    @Test("Resolves the executable from a known install directory when PATH misses it")
    func resolvesFromKnownInstallDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let executable = localBin.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let environment = ["PATH": "/nonexistent"]
        let resolved = DevinRuntime.resolveExecutableURL(environment: environment, homeDirectoryPath: home.path)

        #expect(resolved?.path == executable.path)
    }

    @Test("Reports unavailable when the CLI cannot be found anywhere")
    func reportsUnavailableWhenMissing() {
        let environment = ["PATH": "/nonexistent"]
        #expect(DevinRuntime.resolveExecutableURL(environment: environment, homeDirectoryPath: "/nonexistent-home") == nil)
        #expect(DevinRuntime.isAvailable(environment: environment, homeDirectoryPath: "/nonexistent-home") == false)
    }

    @Test("Ignores non-executable files with the CLI's name")
    func ignoresNonExecutableFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("devin")
        try "not a binary".write(to: path, atomically: true, encoding: .utf8)

        let environment = ["PATH": directory.path]
        #expect(DevinRuntime.resolveExecutableURL(environment: environment, homeDirectoryPath: "/nonexistent-home") == nil)
    }

    @Test("Maps approval modes to permission-mode flag values")
    func mapsApprovalModesToPermissionModeValues() {
        #expect(DevinRuntime.permissionMode(for: .ask) == "normal")
        #expect(DevinRuntime.permissionMode(for: .approveForMe) == "normal")
        #expect(DevinRuntime.permissionMode(for: .fullAccess) == "bypass")
    }

    @Test("Missing CLI message tells the user how to install and authenticate")
    func missingCliMessageIsActionable() {
        #expect(DevinRuntime.missingCliMessage.contains("devin"))
        #expect(DevinRuntime.missingCliMessage.lowercased().contains("install"))
        #expect(DevinRuntime.missingCliMessage.contains("devin auth login"))
    }

    private static func makeExecutable(named name: String) throws -> (directory: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }
}
