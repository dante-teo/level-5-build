import Foundation

/// The Devin runtime process and the tool subprocesses it spawns (e.g. the
/// exec toolbox, the session database) emit structured `tracing`-style logs
/// on stderr: `TIMESTAMP  LEVEL target: message`, for example `INFO
/// toolbox::tools::exec::session_manager: creating PTY session`. `.status`
/// rows are never rendered as transcript rows at all (see
/// `AgentTranscriptState.renderableItems`), so this filter has no effect on
/// what the user sees either way — its only remaining purpose is to keep
/// routine `TRACE`/`DEBUG`/`INFO` tracing noise (which vastly outnumbers
/// anything else on this stream) out of the in-memory transcript state and
/// the durable SQLite cache. `WARN`/`ERROR` lines, and anything that doesn't
/// match the structured format at all (a raw panic, crash, or other
/// unstructured stderr output), are still recorded for that reason, even
/// though they are equally invisible in the UI today.
enum AcpRuntimeLogLine {
    private static let suppressedLevels: Set<String> = ["TRACE", "DEBUG", "INFO"]

    static func isWorthRecording(_ line: String) -> Bool {
        guard let level = tracingLevel(in: line) else { return true }
        return !suppressedLevels.contains(level)
    }

    private static func tracingLevel(in line: String) -> String? {
        let components = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let timestamp = components.first, let level = components.dropFirst().first else { return nil }
        // Guard against incidentally matching an unrelated line by position:
        // require the first token to look like an RFC 3339 timestamp.
        guard timestamp.contains("T"), timestamp.hasSuffix("Z") else { return nil }
        let candidate = String(level)
        guard ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"].contains(candidate) else { return nil }
        return candidate
    }
}
