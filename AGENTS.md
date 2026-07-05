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
- There is no ACP `session/list` call anywhere in `AgentSessionModel`; the sidebar is sourced entirely from `SessionPersistenceStore` via `hydratePersistedSessions`, and `session/load` only ever runs as a silent send-time "prime" (never on selection). Don't reintroduce a discovery RPC call to "fix" a sidebar gap — see `docs/ARCHITECTURE.md`'s "Known accepted regressions" for the intentional trade-off.
- `hydratePersistedSessions` must record a hydrated session's cwd unconditionally and let `reconcileSessionProjectPaths()` (triggered by `setRecentProjects`) decide project-backed eligibility, not gate on `recentProjectPaths` itself at hydration time — `ContentView.selectProject(_ url:)` hydrates before its own recents reload resolves, so gating there silently and permanently loses project-backed status for sessions in a project that isn't in the recents list yet.
