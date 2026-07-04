import Foundation

public final class AcpProcessTransport: @unchecked Sendable {
    private final class StdinWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: FileHandle?

        func setHandle(_ handle: FileHandle) {
            lock.withLock {
                self.handle = handle
            }
        }

        func write(_ line: String) throws {
            let data = Data((line + "\n").utf8)
            let target = lock.withLock { handle }
            guard let target else {
                throw AcpTransportError.failed("process stdin is not available")
            }
            target.write(data)
        }
    }

    public let transport: AcpJsonRpcTransport
    public var events: AsyncStream<AcpEvent> { transport.events }

    private let process: Process
    private let stdinWriter = StdinWriter()
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        eventBufferLimit: Int = 100,
        maxLineBytes: Int = 1_048_576,
        requestTimeout: Duration = .seconds(10)
    ) {
        process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let writer = stdinWriter
        transport = AcpJsonRpcTransport(
            eventBufferLimit: eventBufferLimit,
            maxLineBytes: maxLineBytes,
            requestTimeout: requestTimeout
        ) { line in
            try writer.write(line)
        }
    }

    public func start() throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdinHandle = stdin.fileHandleForWriting
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
        stdinWriter.setHandle(stdin.fileHandleForWriting)

        process.terminationHandler = { [transport] process in
            Task { await transport.emitProcessExit(status: process.terminationStatus, reason: String(describing: process.terminationReason)) }
        }

        try process.run()
        stdoutTask = readLines(from: stdout.fileHandleForReading) { [transport] line in
            await transport.handleLine(line)
        }
        stderrTask = readLines(from: stderr.fileHandleForReading) { [transport] line in
            await transport.emitStderr(line)
        }
    }

    public func terminate() {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func readLines(from handle: FileHandle, consume: @escaping @Sendable (String) async -> Void) -> Task<Void, Never> {
        Task.detached {
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let lineData = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                        await consume(line)
                    }
                }
            }
        }
    }
}
