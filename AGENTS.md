# Agent notes

This repo currently hosts `app/`, a native macOS scaffold using SwiftUI, Swift Package Manager modules, Swift Testing, and XcodeGen. The retired Electrobun POC lives in `legacy/electrobun-app/` for reference only, and `acp-mock-server/` remains active shared test infrastructure. See `docs/adr/0001-native-macos-client.md`, `docs/ARCHITECTURE.md`, and `docs/DESIGN.md`.

## Setup & running

Requires Xcode 16+ and XcodeGen (`brew install xcodegen`) for the native app.

```bash
cd app
xcodegen generate --spec project.yml --project .
swift test
xcodebuild test -project "Level5 Build.xcodeproj" -scheme "Level5 Build" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

## Verification

From `app/`, these should succeed after native scaffold changes:

```bash
swift test
xcodebuild test -project "Level5 Build.xcodeproj" -scheme "Level5 Build" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

Avoid actually launching the GUI unless asked. `script/build_and_run.sh` opens a real window; use it only when local app launch is the intended check.

## Gotchas

- Generated Xcode projects are not committed. Update `app/project.yml`, then regenerate locally with XcodeGen.
- Keep `Resources/Assets.xcassets` as a direct XcodeGen source entry, not a folder reference, so Xcode compiles it with `actool` and emits `Assets.car` plus `AppIcon.icns`.
- Keep `Level5Core` provider-neutral. App-specific SwiftUI code belongs in `Level5BuildApp`.
- `legacy/electrobun-app/` is reference-only. Its old Electrobun/Tailwind gotchas still apply there, but new product work should land in the native app unless explicitly directed otherwise.
- `ContentView`'s `recentProjectStore`/`persistenceStore` parameters default to a lazily-built, shared `Level5Database` at the real `~/.level5build/level5.sqlite`. Tests that construct a `ContentView` and want no on-disk side effects must pass `nil` for *both* parameters explicitly — passing `nil` for only one still evaluates the other's default and touches the real database file.
- New `Level5Core` stores that need durable storage should add their own `static let migrations: [DatabaseMigration]` and take a `Level5Database` in their initializer rather than opening their own `DatabaseQueue`; see `RecentProjectStore`/`SessionPersistenceStore` for the pattern. `Level5Database` composes every store's migrations into one ordered migrator for the single shared connection.
- There is no ACP `session/list` call anywhere in `AgentSessionModel`; the sidebar is sourced entirely from `SessionPersistenceStore` via `hydrateAllPersistedSessions`, and `session/load` only ever runs as a silent send-time "prime" (never on selection). Don't reintroduce a discovery RPC call to "fix" a sidebar gap — see `docs/ARCHITECTURE.md`'s "Known accepted regressions" for the intentional trade-off.
- The sidebar is a single global list of every project's sessions, loaded in full by `hydrateAllPersistedSessions` on `start()`. It is intentionally *not* scoped to whichever project is currently selected for the next new chat — that selection only decides a new session's cwd. Don't reintroduce a per-project-scoped query (e.g. a `listSessionRows(projectKey:)`-style method) for sidebar hydration; use `SessionPersistenceStore.listAllSessionRows()`.
- `hydrateAllPersistedSessions` must record a hydrated session's cwd unconditionally and let `reconcileSessionProjectPaths()` (triggered by `setRecentProjects`) decide project-backed eligibility, not gate on `recentProjectPaths` itself at hydration time — `ContentView.selectProject(_ url:)` hydrates before its own recents reload resolves, so gating there silently and permanently loses project-backed status for sessions in a project that isn't in the recents list yet.
- Real Devin's `session/load` requires both `mcpServers` and `cwd` in its params, or it's rejected outright ("missing field cwd"). `AgentSessionModel.primeSessionForSend` always passes `cwd: key` (a project's key *is* its normalized cwd) — don't revert to `cwd: nil` even though mock ignores it.
- Killing a project's `devin acp` process (approval-mode restart, or app quit) without first calling `session/close` on every session that process created/primed permanently orphans those sessions server-side ("already open in another process" on the next reconnect, even from that same project's own next relaunch). Always route process teardown through `AgentSessionModel.closeSessionsAndTerminateClient`, never `terminateClient` directly, unless the client is already known dead (e.g. `cleanupUnhealthyRuntime` after a process-exit event, where there's nothing left to close). `Level5AppDelegate` (`@NSApplicationDelegateAdaptor`) exists solely to give `AgentSessionModel.prepareForTermination` a chance to run this cleanup before the app process exits — don't remove it as "unused-looking" boilerplate.
- `Level5AppDelegate.applicationShouldTerminate` only fires for a *graceful* Cocoa quit (Cmd+Q, Dock "Quit", `NSApp.terminate(_:)`). `script/build_and_run.sh` restarts the app with `pkill -x`, which sends a raw `SIGTERM` that bypasses that lifecycle entirely — without `Level5AppDelegate`'s `DispatchSourceSignal`-based `SIGTERM`/`SIGINT` handlers (which run the exact same `prepareForTermination` cleanup via `terminateAfterSignal`), every local dev iteration via that script would orphan the previous run's `devin acp` process/sessions. Don't remove those signal handlers as redundant with `applicationShouldTerminate` — they cover different, both-necessary termination paths. (`kill -9`/force-quit still can't be caught by anything; an already-orphaned process from before this fix existed needs manual cleanup, e.g. `pkill -f 'devin.*acp'`.)
- `start()`/`selectProject`/`clearSelectedProject` all eagerly kick off a background `session/new` to prime a project's composer (models/slash-commands) as soon as its client connects (see `primeComposerSession`). Real Devin's ACP server does not handle that `session/new` racing an unrelated `session/load`/`session/prompt` against the *same* process safely. Since project selection isn't restored across launches, `start()` always eagerly primes the home-directory key on every launch — so selecting an already-restored home-directory session and sending immediately after launch used to race this priming (works if you wait a moment or retry, since priming has settled by then). `AgentSessionModel.awaitComposerPriming` (backed by `primingTaskByProjectKey`) sequences `send`/`createSessionAndSend` after any in-flight priming for the same project key; don't bypass it by calling `ensureConnected` directly at the top of those methods.
- `AcpClient.prompt` (i.e. `session/prompt`) must keep its own generous explicit `timeout` override (currently 6h), never the transport's short default meant for quick RPCs like `initialize`/`session/new`. Unlike those, `session/prompt` doesn't resolve until the *entire* turn completes, which routinely exceeds a 10-30s default for any real tool-using turn. Binding it to the short default caused a live, reproduced-in-production bug: the request times out and gets reported as "Prompt failed" while the agent keeps working; its `session/update` notifications (and even the eventual real `session/prompt` response) still arrive but the response is now for a request nobody's waiting on anymore, logged only as a "unexpected response id" diagnostic and otherwise silently dropped — from the user's perspective the reply "never rendered" even though the model/transcript data was never wrong. Detecting a truly stuck turn is `AgentSessionModel`'s idle-activity watchdog's job (`turnIdleTimeoutMilliseconds`, resets on every inbound event) — that's the real timeout mechanism; `prompt`'s own timeout is just a last-resort safety net against a leaked continuation.
