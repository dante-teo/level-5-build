# ADR 0001: Native macOS Client for 1.0

## Status

Accepted.

Current implementation note: the scaffold migration described below has happened. `app/` is now the native macOS app path, and the Electrobun proof of concept lives under `legacy/electrobun-app/` as reference-only material. The native app shell is currently local-only; ACP runtime is implemented (mock and real Devin backends), durable local persistence under `~/.level5build` via SQLite/GRDB is implemented for recent projects, sessions, and transcript caches, and the native Review pane is implemented as inspect-only Git working-tree review (see `docs/ARCHITECTURE.md`). Native release automation now builds signed and notarized DMG artifacts and updates the Homebrew cask; mutating review actions, production-grade retention/eviction, and cross-device sync remain future scope.

## Context

Level5 Build currently ships an Electrobun proof of concept in `app/`. It has proven the product shape: a desktop coding-agent workspace with ACP chat, local session management, permissions, and review-oriented UI direction. The 1.0 product needs deeper macOS integration than the proof of concept can comfortably provide, including native process supervision, native window and menu behavior, local persistence, signed distribution, and a runtime core that can later be reused by non-GUI clients.

The repository also contains `acp-mock-server/`, a standalone ACP test server. Although it was originally useful for the Electrobun app, it is not POC-only infrastructure. Native development and CI need a protocol-clean mock backend so app tests do not require Devin authentication.

## Decision

Level5 Build 1.0 will be a native macOS app.

The native app will take over the `app/` path. During scaffold work, the current Electrobun proof of concept will move to `legacy/electrobun-app/` and remain reference-only. `acp-mock-server/` stays at the repository root as first-class shared test infrastructure.

The native project will use XcodeGen for Xcode project generation and Swift Package Manager for dependencies and shared modules. The minimum OS target is macOS 14.

The runtime will be implemented in Swift. It will supervise agent subprocesses with native `Process`, communicate over newline-delimited JSON-RPC, model the needed ACP surface with focused `Codable` types, and expose a native session adapter to the app. ACP core code must remain provider-neutral. Devin is the only productized provider for 1.0.

The app shell will use SwiftUI with a `NavigationSplitView` layout. Chat remains the primary workspace. Review is a trailing inspector/tool surface where diffs are visible without losing chat context. Approval answering, commit, and revert controls are outside the current inspect-only Review scope.

Core runtime and data modules will be shared Swift modules rather than app-private view code. This keeps the path open for a future TUI or other local clients.

Shared cross-client state will live under `~/.level5build`. Sessions, transcripts, and projects will be stored in SQLite through GRDB. `UserDefaults` and `AppStorage` are limited to small preferences.

The 1.0 app will be an unsandboxed Developer ID app. This matches the product requirement to operate on arbitrary local repositories and shell out to installed developer tools. Distribution will use signed and notarized DMG artifacts plus Homebrew cask updates.

Git operations for 1.0 will shell out to the installed `git` CLI for status, diff, commit, and revert. The app should keep these calls narrow, observable, and tied to selected project roots.

Transcripts will persist locally. Logs and diagnostics must default to redaction. Runtime logging will use Apple's `Logger` / OSLog APIs with privacy annotations, and diagnostics export must produce a redacted bundle suitable for support.

Native CI replaces proof-of-concept CI after the native scaffold lands. The legacy Electrobun app remains a reference, not a required CI target. Mock-backed tests remain required.

## Migration Sequence

1. Write and accept this ADR.
2. In the scaffold issue, move the current Electrobun app from `app/` to `legacy/electrobun-app/`.
3. Create the native macOS `app/` project with XcodeGen, SwiftPM modules, and Swift Testing wired into command-line builds.
4. Keep `acp-mock-server/` at the repository root and use it for native app/runtime tests.
5. Replace proof-of-concept CI with native build and test jobs once the scaffold is in place.
6. Keep release automation aligned with signed, notarized DMG output and Homebrew cask updates.

## Native 1.0 Scope

Native 1.0 is gated on these workflows being usable end to end:

- Chat with Devin through ACP.
- Permission requests and cancellation.
- Review changed files and diffs.
- Commit selected changes.
- Revert selected changes.

The app may include additional supporting surfaces, but these workflows define the required acceptance bar.

## Testing Strategy

Native tests should use Swift Testing. Tests should use fixture repositories and mock ACP subprocess integration so they are deterministic and do not require Devin authentication.

`acp-mock-server/` must remain protocol-clean: stdout is reserved for ACP JSON-RPC messages and diagnostics go to stderr. The mock must cover session list, prompt, permission, cancel, delete, failures, models, and slash commands for native client development and CI.

Scaffold acceptance must include a native command-line build and a Swift Testing setup. Later runtime tests should verify ACP initialization, session lifecycle, prompt turns, permission responses, cancellation, transcript persistence, and git status/diff/commit/revert behavior against fixture repositories.

## Privacy and Persistence

The local state root is `~/.level5build`.

SQLite via GRDB is the source of truth for durable sessions, transcripts, and project records. Preferences that are small, local, and non-relational can use `UserDefaults` or `AppStorage`.

Transcripts are local user data. Logs must not include raw transcript text, prompts, diffs, file contents, tokens, or credentials by default. Where observability needs identifiers, prefer stable opaque IDs, counts, durations, command names, and redacted paths.

Diagnostics export must be explicit user action and must redact sensitive values before writing an export bundle.

## Consequences

The 1.0 codebase will favor Swift, SwiftUI, XcodeGen, SwiftPM, Swift Testing, GRDB, OSLog, native `Process`, and the system `git` CLI.

The current Electrobun implementation remains useful as a product and protocol reference, but new 1.0 feature work should land in the native client once the scaffold exists.

Keeping ACP core provider-neutral preserves testability and future provider options, while productizing only Devin keeps 1.0 scope bounded.

Keeping `acp-mock-server/` outside `legacy/` makes it clear that the mock is active infrastructure, not retired proof-of-concept code.

## Issue Follow-Ups

Update these GitHub issues after this ADR lands:

- Issue #1: make `app/` the native path, move Electrobun to `legacy/electrobun-app/`, and keep mock ACP required.
- Issue #2: reference this ADR as the acceptance artifact.
- Issue #3: specify that scaffold work moves Electrobun to legacy and creates the native `app/`.
- Issue #19: emphasize that mock ACP is required for native development and tests and must remain protocol-clean.
- Issue #20: clarify that native CI replaces proof-of-concept CI after scaffold while mock-backed tests remain required.
- Issue #24: clarify that proof-of-concept retirement does not include retiring `acp-mock-server/`.
