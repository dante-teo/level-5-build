import Testing
@testable import Level5BuildApp

@Suite("ACP runtime log line filtering")
struct AcpRuntimeLogLineTests {
    @Test("Routine tracing INFO/DEBUG/TRACE lines from the runtime's tool subprocesses are not worth recording")
    func routineTracingLevelsAreSuppressed() {
        let lines = [
            "2026-07-05T22:27:22.646681Z  INFO toolbox::tools::exec::session_manager: shell=NonInteractive { shell: Bash } session_id=c1946c [create_session] creating PTY session",
            "2026-07-05T22:27:22.646689Z  INFO toolbox::tools::exec::session_manager: session_id=c1946c [create_session] creating RawExec session",
            "2026-07-05T22:27:22.648925Z  INFO toolbox_core::tools::context: Waiting for stop token 1a21c06e-da6d-4521-b244-6e1553fe977d to stop",
            "2026-07-05T22:27:22.682919Z  INFO chisel_agent::session_db: Saved 2 message nodes (starting from 30) for session splendid-ancient",
            "2026-07-05T22:27:22.682919Z DEBUG chisel_agent::session_db: computing diff",
            "2026-07-05T22:27:22.682919Z TRACE chisel_agent::session_db: entering function",
        ]
        for line in lines {
            #expect(AcpRuntimeLogLine.isWorthRecording(line) == false, "expected \(line) to be filtered")
        }
    }

    @Test("WARN/ERROR tracing lines are still worth recording")
    func warnAndErrorTracingLevelsAreSurfaced() {
        let warn = "2026-07-05T22:27:22.646681Z  WARN chisel_agent::session_db: retrying after transient failure"
        let error = "2026-07-05T22:27:22.646681Z ERROR chisel_agent::session_db: failed to persist session"
        #expect(AcpRuntimeLogLine.isWorthRecording(warn))
        #expect(AcpRuntimeLogLine.isWorthRecording(error))
    }

    @Test("Lines that do not match the structured tracing format are worth recording by default")
    func unstructuredLinesAreSurfacedByDefault() {
        #expect(AcpRuntimeLogLine.isWorthRecording("panic: runtime crashed unexpectedly"))
        #expect(AcpRuntimeLogLine.isWorthRecording("Segmentation fault: 11"))
    }
}
