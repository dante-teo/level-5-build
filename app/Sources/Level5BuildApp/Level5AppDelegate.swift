import AppKit
import Darwin
import Dispatch

/// Backs `@NSApplicationDelegateAdaptor` in `Level5BuildApp`. Its only job is
/// giving `AgentSessionModel` a chance to gracefully close every session its
/// spawned backend processes still hold open before the app process exits —
/// see `AgentSessionModel.prepareForTermination`. Conforming to
/// `ObservableObject` lets SwiftUI inject this instance into the
/// environment automatically, so `ContentView` can register its model's
/// termination handler without any other plumbing (there is no
/// `AppDelegate` today otherwise; see `docs/ARCHITECTURE.md`).
@MainActor
final class Level5AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Set by `ContentView` once its `AgentSessionModel` exists. `nil` (e.g.
    /// in a context that never finished launching a window) just terminates
    /// immediately rather than hanging quit.
    var terminationHandler: (() async -> Void)?
    private var isTerminating = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `applicationShouldTerminate` only fires for a *graceful* Cocoa
        // quit (Cmd+Q, Dock "Quit", `NSApp.terminate(_:)`). A raw POSIX
        // signal — notably `SIGTERM`, which is exactly what
        // `script/build_and_run.sh`'s `pkill -x` sends to replace a
        // previous run during local development — bypasses that lifecycle
        // entirely and, before this handler existed, killed the process
        // without ever calling `prepareForTermination`, orphaning every
        // spawned `devin acp` process with its sessions still considered
        // "open" (and therefore refused by a `session/load` from the next
        // launch's fresh process). Installing a `DispatchSourceSignal` lets
        // ordinary Swift/async code run in response instead of being
        // constrained by async-signal-safety like a raw `signal()` handler
        // would be. `signal(_:SIG_IGN)` first is required so the default
        // "terminate immediately" disposition doesn't win the race against
        // the dispatch source picking up the same signal.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.terminateAfterSignal()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func terminateAfterSignal() {
        guard !isTerminating else { return }
        isTerminating = true
        guard let terminationHandler else {
            exit(0)
        }
        Task { @MainActor in
            await terminationHandler()
            exit(0)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        guard let terminationHandler else { return .terminateNow }
        Task { @MainActor in
            await terminationHandler()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
