# Architecture

## Native macOS 1.0 direction

[ADR 0001: Native macOS Client for 1.0](adr/0001-native-macos-client.md) defines the accepted migration direction. The native macOS client owns `app/`, and the Electrobun proof of concept lives in `legacy/electrobun-app/` as reference-only migration material.

`acp-mock-server/` remains active shared test infrastructure for the native client and future clients. It must not move into `legacy/` with the Electrobun proof of concept.

## Repo layout

This repo currently hosts:

- `app/`, the native macOS scaffold using SwiftUI, Swift Package Manager modules, Swift Testing, and XcodeGen.
- `legacy/electrobun-app/`, the retired Electrobun proof of concept kept as reference-only migration material.
- `acp-mock-server/`, a standalone Node/TypeScript Agent Client Protocol mock server for local client and integration testing.
- `script/`, root-level local app run helpers.
- `docs/`, shared architecture/product/design documentation.

The mock server remains usable as a standalone stdio ACP server and protocol fixture. For native app development, the app connects to the mock through an independently started TCP wrapper; Devin production runtime integration remains future work.

## `acp-mock-server/` — ACP test agent

`acp-mock-server/` is a dependency-light Node/TypeScript implementation of an ACP v1 agent over newline-delimited JSON-RPC stdio. It is designed for testing client UI and protocol handling without a real model or real code edits.

### Transport and process model

- The protocol entrypoint is `acp-mock-server/start.sh`, which builds stale or missing TypeScript output with pnpm and execs Node.
- The server reads UTF-8 JSON-RPC messages from stdin and writes only JSON-RPC messages to stdout.
- The native app development entrypoint is `acp-mock-server/start-tcp.sh`, which exposes the same mock lifecycle over TCP on `127.0.0.1:58945` by default. Use `script/run_mock_app.sh` to start the TCP server, wait for the port, and launch the macOS app.
- Logs go to stderr. Do not route diagnostic output to stdout; ACP clients expect stdout to be protocol-clean.
- Session state persists to `.mock-acp-state.json` by default, ignored by git. Override with `ACP_MOCK_STATE_PATH`.
- `runServer()`'s stdin loop dispatches each parsed line without awaiting the previous line's handler to finish. This is load-bearing, not stylistic: a request handler can call back into the client mid-flight (e.g. a prompt turn's `session/request_permission`), and that callback's answer can only ever arrive as a later stdin line. If the loop awaited each line to completion before reading the next one, the server would block forever waiting on its own unread response. In-process tests that call `AcpMockServer.handleLine()` directly (`tests/server.test.ts`) can't exercise this class of bug, since they never go through the loop; `tests/subprocess.test.ts` drives the real `start.sh` entrypoint over an actual stdio pipe specifically to catch it.

### Mocked ACP surface

The mock supports initialization, auth/logout, session lifecycle (`new`, `load`, `resume`, `close`, `list`, `delete`), prompt turns, cancellation, legacy modes, session config options, slash commands, permission requests, model discovery/switching, and mock extension methods under `_mock/*`.

By default, its advertised surface is intentionally Devin-like and app-relevant: visible config is limited to `model`, visible slash commands are `help`, `plan`, `review`, `fix`, and `test`, and mock-only `_mock/*` helpers are callable but not advertised through initialization metadata. `_mock/list_slash_commands` intentionally returns both visible commands and hidden QA commands for direct protocol probing.

Permission requests aren't just a standalone demo path: the edit scenario (triggered by `/fix`, or a prompt containing "edit"/"fix"/"refactor") sends a `session/request_permission` for its simulated diff before applying it, so approval-mode UI can be exercised without needing the literal word "permission"/"approve" in the prompt. A dedicated scenario triggered by those exact words (`permissionScenario`) still exists for direct testing. `/progress-demo` and prompts containing "progress demo" run a deterministic all-in-one QA turn with message streaming, plan updates, successful and failed/permission-gated tool states, usage threshold updates, and final `end_turn`.

The server emits realistic `session/update` notifications for:

- agent/user message chunks
- plans
- tool calls and tool call updates
- usage updates
- slash command availability
- current mode changes
- config option updates
- session info/title updates

Initial session notifications are intentionally emitted after the `session/new` response so clients can create per-session UI state before handling updates.

`usage_update.size` is derived from the selected mock model context window (`mock-fast` 64k, `mock-pro` 200k, `mock-deep` 1M), so the app's context indicator can be tested against model changes.

### Model and command testing

Model selection is exposed through the ACP-native `configOptions` response (`configId: "model"`, set with `session/set_config_option`) and through direct mock extension methods (`_mock/list_models`, `_mock/set_model`). Slash commands are advertised with `available_commands_update` so autocomplete and command-palette UI can be tested without adding real agent logic. Hidden prompt phrases such as `fail`, `progress demo`, `refuse`, `max tokens`, `permission`, and `web` / `fetch` still exercise QA edge states without appearing in the visible slash-command menu; `_mock/list_slash_commands` exposes hidden commands, including `/progress-demo`, for native composer discovery.

### Manual testing with the legacy app

The retired Electrobun app does not use the mock server for normal chat/session work unless `LEVEL5_USE_ACP_MOCK=1` is set. The convenient manual command for inspecting that legacy behavior is:

```bash
cd legacy/electrobun-app
bun run dev:mock
```

Use `./start.sh` from `acp-mock-server/` when manually testing stdio protocol behavior outside the app. Use `./script/run_mock_app.sh` from the repo root for the native app mock path.

Mock-mode app runs use `~/.level5-build/acp-mock-state.json` for state unless `ACP_MOCK_STATE_PATH` is set. Override the mock TCP address with `LEVEL5_ACP_MOCK_HOST` and `LEVEL5_ACP_MOCK_PORT`; the native app does not spawn or supervise the mock process.

### Verification

From `acp-mock-server/`:

```bash
pnpm install
pnpm run build
pnpm run typecheck
pnpm test
```

From the repo root:

```bash
bash -n script/build_and_run.sh
bash -n acp-mock-server/start.sh
bash -n acp-mock-server/start-tcp.sh
bash -n script/run_mock_app.sh
```

Use `./start.sh` for ACP stdio smoke tests instead of package-manager script wrappers; command banners before process output would pollute ACP stdout.

## `app/` — native macOS app

Stack: SwiftUI for the app shell, Swift Package Manager for module layout and command-line tests, Swift Testing for tests, and XcodeGen for the generated Xcode project. The generated `.xcodeproj` is local build output and is not committed. The app uses SwiftUI Introspect narrowly where SwiftUI does not expose the needed native control state; currently this is limited to transcript scroll tracking against the underlying `NSScrollView`.

The scaffold requires Xcode 16 or newer because `Package.swift` uses Swift 6 and the tests use Swift Testing.

The active app identity is:

- Product name: `Level5 Build`
- Bundle identifier: `io.anvia.level5.build`
- Version: `0.0.0`
- Minimum OS: macOS 14

### Native scaffold layout

```text
app/
├── Package.swift
├── project.yml
├── Resources/
│   └── Assets.xcassets/
├── Sources/
│   ├── Level5BuildApp/
│   │   ├── Models/
│   │   └── Views/
│   ├── Level5Design/
│   └── Level5Core/
└── Tests/
    ├── Level5BuildAppTests/
    ├── Level5DesignTests/
    └── Level5CoreTests/
```

`Level5Core` is the provider-neutral module where reusable runtime/domain code will grow. It owns recent-project persistence, native project Git status, and provider-neutral ACP primitives. `Level5Design` owns reusable SwiftUI design primitives and bundled in-app identity/font resources. `Level5BuildApp` is the SwiftUI app target.

`Level5Core`'s ACP layer is intentionally hand-coded and tolerant rather than generated from a full schema. It includes reusable `Codable` protocol values, JSON-RPC envelopes, method constants, a newline-delimited JSON-RPC transport actor, a thin `AcpClient`, and a generic `AcpProcessTransport` wrapper around native `Process`. Unknown forward-compatible fields are tolerated where possible; required identifiers and discriminators remain strict. This keeps the core provider-neutral while covering the ACP surface the native app and mock tests currently need.

`Level5Core.ProjectGitStatusService` is also provider-neutral. It shells out only through native `Process`, never from SwiftUI views, and returns a non-throwing unavailable status if Git cannot be queried. Each Git command has a short timeout. Status collection follows the current product contract: discover the repository root with `git -C <cwd> rev-parse --show-toplevel`, parse `git status --porcelain=v1 --branch`, resolve detached `HEAD` to a short SHA, and sum text line changes with `git diff --numstat <base> --`. Repositories with no commits diff against Git's empty tree. Untracked files count toward changed-file totals, but their contents do not count toward line totals; binary numstat rows are ignored.

The current app UI is a native shell. `ContentView` owns window-scoped shell state and composes:

- `ShellSidebarView` for New Chat, ACP-backed session rows, fixed trailing state indicators, Load More, and confirmed context-menu delete actions.
- `WorkspaceView` and `TranscriptView` for the empty new-session state plus compact rendering of the active structured transcript.
- `ComposerView` for native prompt drafting, file attachments, model selection, approval-mode selection, slash-command insertion, permission-request takeovers, backend unavailable state, and the visible per-session queue.
- `AgentSessionModel` for app-private session lifecycle, transcript caches, per-session queues, backend availability, and ACP event routing.
- `ShellCommands` for scene-level menu commands routed through focused values.

Backend selection is explicit and layered. In DEBUG builds only, `LEVEL5_USE_ACP_MOCK=1` selects the repo-local ACP mock backend; release/Homebrew-style builds ignore mock env vars. Otherwise `DevinRuntime` scans `$PATH` plus known install directories (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) for a `devin` executable and, if found, selects the real Devin backend. If neither is available, agent actions are disabled and the composer shows product UI for "Agent runtime unavailable" with an actionable install/auth message; the active app path never appends fake local placeholder responses.

In mock mode, the app connects to the independently running TCP mock server through `Level5Core.AcpClient`, initializes ACP, and calls `session/list` on startup. Existing mock sessions appear in the sidebar using provider `updatedAt` plus app-observed activity for recent-first ordering. `nextCursor` renders as Load More. New Chat is only an unsent draft: it creates no hidden ACP session and appears in no sidebar row until first send. First send calls `session/new`, inserts/selects the row, appends the user prompt when the turn starts, then sends `session/prompt`. Selecting an existing row calls `session/load`. It does not eagerly clear that session's in-memory transcript state: any durably cached transcript paints immediately (see Durable session/transcript persistence below), and that cache is only discarded in favor of backend replay once the first raw `session/update` for that session actually arrives, so ACP remains the source of truth without an empty-flash in between. Selection is not activity for sidebar ordering; live user/agent chunks sent or received after replay are activity and can move the row. Delete is exposed only from a row context menu, requires native destructive confirmation, calls `session/delete`, refreshes the list, and returns to New Chat when the active session was deleted.

In Devin mode, `AgentSessionModel` supervises one spawned `devin --permission-mode <mode> acp` process per project directory rather than a single shared connection, keyed by normalized project path (a synthetic key covers the home-directory fallback when no project is selected). This gives true concurrent sessions across different projects: each project's client has its own event stream, ACP client generation counter, and turn/permission state, so one project's process exiting, timing out, or streaming events cannot leak into another project's transcript. The same isolation applies to the global `availability`/`runtimeMessage` status banner and to `activeSessionId`: these are singleton, foreground-scoped properties gated by `isActiveProjectKey`, reflecting only the active session's project (or the selected "new chat" project when none is open). A background project's connection failure, turn completion, permission event, or idle-timeout cancellation updates only that project's own sidebar rows (`isRunning`, `isAwaitingPermission`, `hasCompletedTurn`); it must never overwrite the banner or reset the session the user is currently viewing. Selecting a "new chat" project eagerly connects that project's process and loads its own session list into the (merged, multi-project) sidebar, without evicting rows that belong to other still-running projects. Approval-mode changes restart the affected project's process with a new `--permission-mode` flag rather than trying to change it live: empirically, the ACP `session/set_mode` method only affects the agent's Normal/Plan/Ask conversation mode, not tool-approval enforcement, so there is no reliable in-place way to change permission enforcement for a running process. If a project has a turn in flight when approval mode changes, the restart is deferred until that turn completes so in-flight work is never killed. Because Devin has no request/response API for listing models or slash commands outside of a session, `AgentSessionModel` derives them from the `session/new`/`session/load` result's `configOptions` and from live `session/update` notifications (`config_option_update`, `available_commands_update`) instead of the mock-only `_mock/list_models` / `_mock/list_slash_commands` extension methods. Both `session/new` and `session/load` require an (even empty) `mcpServers` array in their params for real Devin, or the call is rejected outright.

Because a fresh "new chat" composer would otherwise show no models/slash-commands/skills until the user's first send, `AgentSessionModel` primes it eagerly: as soon as a project's client connects (app launch for the home directory, or `selectProject`/`clearSelectedProject`), it silently calls `session/new` to populate real config/commands, without creating a visible sidebar row. The first real send reuses that primed session instead of creating another one. This is safe because Devin only persists a session to its own session store after its first message — an abandoned priming session (e.g. the user switches projects before sending) is never written to disk and never appears in `session/list`. Selecting an *existing* sidebar session already connects and calls `session/load` immediately (not deferred to the next send); real Devin also requires `mcpServers` here.

Known Devin ACP gap: `session/delete` is not implemented by the real agent (`Method not found`), unlike the mock server, and the backend keeps listing the session forever. Sidebar deletion does not require server agreement to work: `AgentSessionModel.deleteSession` calls `session/delete` best-effort and removes the session locally either way, then durably remembers the deletion (see Durable session/transcript persistence) so the row cannot resurrect from a later `session/list`/`session/update`, on Devin or any other backend that can't (or doesn't) forget it server-side.

The native lifecycle model permits multiple sessions across multiple projects to have running turns concurrently, but only one active turn per session. Running state is tracked by per-session active-turn records, not a global boolean: each record has a local turn ID, the ACP client generation (scoped per project) that owns its event stream, a watchdog, and the latest inbound activity timestamp. Sending again while the active session is running queues an immutable structured composer snapshot in that session's in-memory FIFO queue. Queued prompts render compactly above the composer and can be removed before they start. Queued prompts move into the transcript only when they begin sending. If a queued prompt fails, the model records an error row and continues to later queued prompts.

The composer draft is an app-private value model. It stores text segments, accepted slash-command tokens, selected model, and up to 10 deduped standardized file attachment URLs. Attachments are not read by the client; prompt serialization sends one ACP text block when serialized text is non-empty followed by `resource_link` blocks with `file://` URIs and basename names. Empty text with attachments is valid; empty text with no attachments is not sent. The editor starts at one text line, grows from measured `NSTextView` content, and caps at 12 lines before the scroll view handles overflow.

ACP model and slash-command discovery is backend-driven. On startup, mock mode initializes ACP and calls the mock discovery extensions (`_mock/list_models` and `_mock/list_slash_commands`) so New Chat can render the selector and command menu before first send. Session load/create reads model config from ACP `configOptions` where `id == "model"` and treats backend config updates as authoritative unless a local model change is in flight. Existing-session model changes call `session/set_config_option`, update the selector optimistically, and roll back with a composer status error on failure. Rollbacks are scoped by session id, so reconnect failures clear the pending save state and async failures after a session switch do not mutate the visible draft for a different session. First send applies a pending New Chat model only when it differs from the session's reported model, then sends the structured prompt blocks.

Approval mode is app-private state owned by `AgentSessionModel` and persisted per backend in `UserDefaults`. The supported modes are `Ask for approval`, `Approve for me`, and `Full access`. `Ask for approval` stores parsed ACP `session/request_permission` requests by `sessionId`; pending requests for the visible session replace the composer with a permission takeover, while background-session requests leave the active composer usable and mark the relevant sidebar row as awaiting approval. `Approve for me` currently auto-selects an allow-like option for the mock backend, falling back to the first backend-provided option, and appends a compact status note. `Full access` uses the same allow-like fallback without a status note. Permission responses are explicit selected-option replies: `{ "outcome": { "outcome": "selected", "optionId": "<id>" } }`. Cancelled permission requests use ACP's cancelled outcome: `{ "outcome": { "outcome": "cancelled" } }`. Reject-with-instructions chooses a reject-like option if available, otherwise the last option, then sends the typed instructions as the next prompt for that same session through the existing per-session queue/send path; the instruction text is not serialized into the ACP permission response.

`Level5BuildApp` owns an app-private structured transcript layer:

- `AgentTranscriptEvent` is the normalized event stream from ACP updates and prompt outcomes.
- `AgentTranscriptReducer` is pure and deterministic, merging message chunks by `messageId`, falling back to contiguous same-role message merging when no ID exists, storing structured plan state, merging tool updates by `toolCallId`, tracking latest usage metadata, and storing every stop reason.
- `AgentTranscriptState` is held per `sessionId` by `AgentSessionModel`. It stores ordered transcript items plus active plan state, latest usage, latest error, tool expansion state, and stop-reason metadata.
- `AgentTranscriptNormalizer` converts tolerant raw ACP `session/update` JSON into transcript events while preserving unsupported non-text content as unsupported-block counts. Unsupported-only message blocks keep empty text and render from that count so the UI does not duplicate placeholder text.

Transcript rendering is intentionally compact. User and agent messages render as chat rows. Plan and usage updates do not render transcript rows: the active session's plan renders as a centered composer-adjacent `Plan N/M` chip with a checklist popover, while usage renders only as the context ring immediately left of the model selector. Tool, status, error, and notable stop-reason items render as operational transcript rows with normalized human-readable content only; tool rows auto-expand while `in_progress`, auto-collapse when `completed` unless manually expanded, and remain expanded when `failed`. Expanded tool rows expose a small normalized detail area for status, kind, and readable detail text; collapsed rows keep a one-line preview. Ordinary `end_turn` stop reasons are stored as metadata and do not render a row; notable stops such as `cancelled`, `refusal`, and `max_tokens` render compact status rows. Terminal panes, diff rendering, and raw JSON inspection remain out of scope.

The context ring appears only when positive `used` and `size` usage values are present for the active session. It animates progress and color changes, uses accent below 70%, warning from 70%, and danger from 90%, and disables pulse-style motion when Reduce Motion is enabled. Its hover/focus/click popover shows percent used, tokens left, used/size tokens, and optional cost.

Project-backed active sessions expose an adaptive project dashboard. A session is project-backed only when it came from an explicit selected recent project, or when an existing backend-listed session has a `cwd` matching a persisted recent project. The home-directory fallback used for folderless mock sends is not project-backed, and backend `cwd` values are not auto-added to recent projects. The dashboard is shown for project-backed sessions even when the folder is not a Git repository; non-Git folders render project metadata with unavailable Git status.

Dashboard state is event-driven and in memory with the active transcript state. `AgentSessionModel` refreshes it on project/session changes, dashboard visibility changes, send/end-turn/activity edges, and explicit refresh actions. It does not use filesystem watchers or polling. Async Git refreshes carry a generation token so stale results after a session or project switch are ignored.

Dashboard references are derived best-effort from ACP tool content, locations, `_meta`, and `metadata` because ACP does not currently expose a first-class sources contract. Web URLs and local files outside the active project root are retained; project-local file reads are filtered out to avoid noisy source lists. References dedupe by stable identity (`kind` plus `uri`) rather than title, preserving the first title seen so duplicate metadata cannot produce duplicate SwiftUI row IDs.

Transcript auto-scroll is per-session follow-tail state. Sessions follow the tail by default; user scroll-up disables auto-follow for that session, and scrolling back to the bottom re-enables it. Reselecting a session preserves its existing follow-tail state instead of forcing a jump to the bottom. This is intentionally in-memory only and does not survive a relaunch, unlike the durable transcript cache described below.

`TranscriptView` renders rows with SwiftUI but uses SwiftUI Introspect to access the backing macOS `NSScrollView` for scroll state. The controller derives "at bottom" from the actual document bounds, visible rect, viewport height, and AppKit flipped-coordinate behavior; content changes settle to bottom only while the session was already following the tail. Wheel, trackpad, scrollbar-drag, and key-scroll input cancel any pending programmatic settle so manual reading is not fought by streaming updates.

The session model appends an optimistic local user row only when a prompt actually starts. It tracks pending backend user echoes per session so replayed/streamed backend echo chunks can be suppressed. If a prompt fails before its backend echo arrives, the pending optimistic echo entry is removed so later successful prompts cannot duplicate user rows. After manual Stop, the pending echo queue is also the handoff signal for immediate re-prompts: late cancelled-turn output stays suppressed until the backend echoes the new prompt's user message, then live output for that session is accepted again.

ACP event handling routes updates by `sessionId`, handles structured transcript events, session title/timestamp updates, diagnostics, stderr, process exits, and policy-driven permission requests. Manual Stop is treated as normal ACP cancellation for the selected active session: the model immediately marks that turn stale, restores composer editing, clears queued prompts for that session, sends `session/cancel`, cancels any pending permission request, preserves transcript content already streamed, suppresses late output from that stale turn, and keeps a healthy ACP connection alive. The stale marker is not cleared just because a new prompt starts in the same session; it clears only when the backend echo for that new prompt completes, preventing cancelled-turn output from leaking into an immediate re-prompt. Idle timeout and process exit are treated as unhealthy runtime recovery paths: active turns and permission state are cleared, the old ACP generation is invalidated, a transcript error/status is appended, the client is reset, and the next user action reconnects. The default idle timeout is 120 seconds and can be overridden with `LEVEL5_ACP_TURN_IDLE_TIMEOUT_MS`; watchdogs pause while their session is waiting on human permission, including background-session permission requests. Sidebar state precedence is awaiting permission, running, successful completion, then idle; successful completion is set only after `end_turn` and clears on next activity in that session.

### Durable session/transcript persistence

`Level5Core.Level5Database` owns the single `DatabaseQueue` connection and single `DatabaseMigrator` for the ADR-mandated SQLite file at `~/.level5build/level5.sqlite`; GRDB recommends one writer connection per file, and two independent `DatabaseQueue`s to that file would work but buy nothing. Each store still defines and owns its own named migrations as locality-preserving `static` arrays (`RecentProjectStore.migrations`, `SessionPersistenceStore.migrations`); `Level5Database` only composes them into one explicit, ordered list at construction. `RecentProjectStore` accepts an injected `Level5Database` (or, via a convenience initializer that opens its own scoped `Level5Database`, a bare `databaseURL`) instead of always opening its own queue. `ContentView` builds one shared `Level5Database` and hands it to both `RecentProjectStore` and `SessionPersistenceStore` by default; callers that want no on-disk persistence (tests) pass `nil` for both stores explicitly.

`Level5Core.SessionPersistenceStore` is provider-neutral and shape-agnostic about transcript internals: it only ever sees `(kind: String, payload: Data)`, so it stays reusable by a future non-GUI client. Three tables back it: `sessions` (one row per known session — `sessionId`, `projectKey`, `backend`, `title`, `detail`, `providerUpdatedAt`, `observedAt`, `createdAt`, indexed on `(projectKey, observedAt)`); `session_transcript_items` (ordered per-item rows — messages/tools/statuses/errors — keyed by the same stable ids the in-memory reducer already uses, `UNIQUE(sessionId, itemId)`, ordered by autoincrementing `id` so upserts preserve first-insertion order without an app-maintained sequence counter); and `session_transcript_state` (one row per session for the singleton plan/usage/stop-reasons/references JSON fields that aren't an ordered list). Transcript tables reference `sessions(sessionId) ON DELETE CASCADE` (GRDB enables `PRAGMA foreign_keys` by default), so `deleteSession` alone removes every row for a session. Explicitly not persisted: `isRunning`/`isAwaitingPermission`/`hasCompletedTurn` (live turn-state, correctly reset to false after a relaunch) and per-tool manual expand/collapse overrides (reset to the default expand-while-running/collapse-when-done heuristic after a relaunch).

`Level5BuildApp.TranscriptPersistenceCoding` owns the encode/decode boundary: small `Codable` DTOs mirroring `AgentTranscriptMessage`/`Tool`/`Status`/`Error`/`AgentPlanState`/`AgentTranscriptUsage`/`[AgentReference]`, plus pure mapping functions to/from `AgentTranscriptState`. `AgentTranscriptReducer` stays pure/IO-free; all persistence awareness lives in `AgentSessionModel`, which holds an injectable `persistenceStore: SessionPersistenceStore?` (`nil`/fake in tests, matching the `approvalModePreferenceStore` pattern).

On `start()`, before `ensureConnected`/`session/list` resolve, `AgentSessionModel` synchronously loads that project's persisted session rows into the sidebar so it is never empty at launch; once `session/list` succeeds, its rows win as usual. A full refresh (reset) goes through `upsert`, the same write-through every live update uses. Load More persists too, but deliberately does not call `upsert` for rows the sidebar already knows about: it only appends and persists genuinely new rows, so a page that happens to repeat an already-known id can't clobber that row's locally-tracked `observedAt`/live turn-state with the plain fetched summary. Pruning is delete-only: a row absent from a fresh `session/list` page/reset is never removed from disk, only an explicit `deleteSession` removes it, so Load-More'd history surviving a relaunch is not erased by the in-memory reset that already happens on every project switch.

Deletion does not require the backend's agreement. `deleteSession` calls the ACP `session/delete` RPC best-effort — its failure (or the client being unreachable) does not block anything, because some backends (real Devin) don't implement it at all — then unconditionally removes the session's in-memory state, evicts its cached rows from `SessionPersistenceStore`, and records the id in a small durable `hidden_sessions` table (`SessionPersistenceStore.markSessionHidden`/`.hiddenSessionIds()`, loaded into memory once at `AgentSessionModel` construction). Every path that could otherwise resurrect a row — `session/list` (both the reset and Load More branches), a background `session/update`'s `session_info_update` fallback, and `ensureSessionRowExists` for a lingering permission request — is filtered against that hidden set, so a session the user deleted locally stays gone even if the ACP server keeps reporting or streaming updates for it, and even across a relaunch.

Selecting a session synchronously hydrates its cached transcript from disk before the async `session/load` call, so switching into (or relaunching into) a session paints instantly instead of flashing empty. The in-memory transcript is *not* eagerly cleared at that point; instead, the existing `loadingSessionIds` flag is the gate: the first raw `session/update` notification received for a session while it is still marked loading discards the cache and starts a fresh state, and only then does replay populate it. This hooks the raw per-session update dispatch rather than the `apply(_:to:)` convenience wrapper, because some replay-only sessions produce zero renderable events (e.g. `session_info_update`/`config_option_update`, which `AgentTranscriptNormalizer` filters out) and gating on `apply` would leave stale cache displayed forever in that case. The reset is mandatory rather than optional because the reducer merges by `messageId` (`text +=`), so replaying on top of un-cleared cache would duplicate content instead of replacing it. Net effect: cache paints immediately, then gets fully swapped for live replay content the moment real data starts arriving, matching "ACP remains the source of truth when available" while removing the empty-flash on every session switch. If the backend never responds (disconnected/unavailable, or simply has nothing to say), the hydrated cache simply stays displayed — graceful degradation, no special-case code needed.

Writes are not debounced. Every `apply(_:to:)` call touches only the one or two transcript rows the event actually changed — ids driven by an explicit `messageId`/`toolCallId`/`replacementKey` are deterministic, and the reducer's two "no explicit id" paths (message merge/append with no `messageId`, status/error append with no `replacementKey`) always land on the trailing item — and writes them via `Task.detached(priority: .utility)` off the main actor. This avoids a wall-clock debounce's complexity (an injectable clock, a termination-flush path — the app has no `AppDelegate` today) for a write volume that is already granular; revisit only if profiling shows it matters at fast token-streaming rates. `upsert(_:)` for sidebar rows write-throughs to the `sessions` table inline instead, since those writes are cheap and infrequent (same style `RecentProjectStore` already uses).

Corruption and versioning degrade gracefully rather than erroring. A bad JSON payload on a single cached transcript row is caught by `TranscriptPersistenceCoding.decode`/`.apply` and that row is simply skipped (a cache miss), never aborting the rest of hydration; `SessionPersistenceStore` itself never trusts a raw `Row` subscript that could trap on a type mismatch; a row it cannot decode is deleted so it cannot repeatedly fail. `payloadVersion` mismatches are treated as a cache miss, not an error, since this is a cache and not the source of truth — no migration logic is needed for the transcript payload shape itself. Store construction is `try?`-tolerant at the `ContentView` level, same as `RecentProjectStore` today: failure to open the database disables persistence, not the app.

Non-goals: queued/unsent prompts, composer drafts, and manual tool-expansion overrides are not persisted across a relaunch; there is no retention/eviction cap on cached sessions/transcripts yet; there is no cross-device/cloud sync.

### Native project context

The native app supports local project context selection only in the new-session composer footer. The selected project is window-local `AgentSessionModel` state (`selectedProject`, on the `@State` instance `ContentView` owns), is not restored on launch, and becomes locked once a session is active because `isProjectSelectionAvailable` mirrors `isNewSession`, which `selectProject`/`clearSelectedProject` both guard on. Starting a New Chat clears the draft/transcript and makes project selection available again while preserving the current window-local project selection.

Recent project folders are persisted by `Level5Core.RecentProjectStore` with GRDB, sharing the `Level5Database` connection described above at `~/.level5build/level5.sqlite` for runtime. Tests must inject a temporary database (or database URL). The `recent_projects` table uses the normalized absolute path as its primary key and stores `displayName`, `createdAt`, and `lastOpenedAt`.

Path normalization uses `URL(fileURLWithPath: path).standardizedFileURL.path`; it does not resolve symlinks. Any existing directory is a valid project folder, regardless of Git/package metadata. Upserting a selected folder updates `lastOpenedAt`, keeps the original `createdAt`, and prunes the table to the 10 most recently opened projects. Missing paths are not deleted automatically; the picker displays them disabled and lets the user remove them.

The selected project path is exposed as local shell state. In mock mode it is used as ACP `cwd` for first send from New Chat; folderless mock prompts use the home directory. Selecting an existing ACP session reloads provider state and does not change that session's cwd unless the backend chooses to honor a future cwd update.

### Build / dev flow

From `app/`:

```bash
xcodegen generate --spec project.yml --project .
swift test
LEVEL5_RUN_ACP_PROCESS_INTEGRATION=1 swift test
xcodebuild test \
  -project "Level5 Build.xcodeproj" \
  -scheme "Level5 Build" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

The pure ACP transport tests are marked serialized because they intentionally exercise request cancellation, request timeout, and `failAll` cleanup against shared actor/task scheduling. Keep that suite serialized unless the helper waits are redesigned to be independent under Swift Testing's default intra-suite parallelism. The process-transport integration is opt-in through `LEVEL5_RUN_ACP_PROCESS_INTEGRATION=1` because it launches `acp-mock-server/start.sh` as a real subprocess.

From the repo root, `script/build_and_run.sh` builds the Swift package, stages `dist/Level5 Build.app`, and launches it. Normal verification should use the test commands above and should not launch the GUI unless that is explicitly intended.

### Native app assets

The native app icon lives in `app/Resources/Assets.xcassets/AppIcon.appiconset`. `app/project.yml` must reference `Resources/Assets.xcassets` directly, not as a copied folder, so Xcode's asset catalog compiler emits `Assets.car` and `AppIcon.icns` into the app bundle.

## `legacy/electrobun-app/` — Electrobun reference app

Stack: [Bun](https://bun.sh) (runtime + main process), [Electrobun](https://blackboard.sh/electrobun) (desktop app shell using the OS's native webview — WKWebView on macOS, WebView2 on Windows, webkit2gtk on Linux — not a bundled Chromium/CEF; `bundleCEF` is explicitly disabled for all platforms), React 18, Jotai for webview UI state, [`use-stick-to-bottom`](https://github.com/stackblitz-labs/use-stick-to-bottom) for the transcript's auto-scroll/stick-to-bottom behavior, Vite 6 (bundles the webview UI), Tailwind CSS v4, and a manually-configured shadcn/ui foundation.

This app is reference-only and should not receive new product work unless a task explicitly targets the legacy implementation.

Electrobun is not Electron — it has a different architecture and API surface. Don't assume Electron APIs/patterns apply.

### Process model

- **Main process** (`legacy/electrobun-app/src/bun/index.ts`, runs under Bun): creates the `BrowserWindow`, owns app lifecycle, and implements the bun-side RPC handlers.
- **Webview** (`legacy/electrobun-app/src/mainview/`): a normal React SPA. Vite's project root is `src/mainview`; it builds to `legacy/electrobun-app/dist`.
- **Webview state** (`legacy/electrobun-app/src/mainview/state/`): small Jotai atoms for cross-component UI state such as sidebar collapse and width.

### Build / dev flow

- `bun run start`: `vite build` bundles the webview into `legacy/electrobun-app/dist`, then `electrobun dev` runs the main process against the bundled assets. `electrobun.config.ts`'s `build.copy` maps `dist/index.html` -> `views/mainview/index.html`, `dist/assets` -> `views/mainview/assets`, and fixture/runtime assets -> their app resource locations; the main process loads the webview from the `views://mainview/index.html` custom protocol.
- `bun run dev`: runs `electrobun dev --watch` without rebuilding the Vite webview first. Use it only when bundled assets already exist or the change is limited to Electrobun-side files.
- `bun run dev:hmr`: runs a live Vite dev server (`localhost:5173`) alongside `bun run start`. `legacy/electrobun-app/src/bun/index.ts` probes the dev server on startup (only when the Electrobun update channel is `"dev"`) and points the window at it instead of the bundled `views://` assets when it's reachable, enabling HMR.
- `bun run build`: production build (`vite build && electrobun build`).
- `bun run build:stable`: stable macOS release build (`vite build && electrobun build --env=stable`). Electrobun emits release artifacts under `legacy/electrobun-app/artifacts/`.
- `bun run release:package:mac -- v0.0.0`: copies Electrobun's stable DMG to a versioned GitHub Release artifact name.
- `bun run release:cask`: writes `Casks/level5-build.rb` in the Homebrew tap checkout using the release artifact name and SHA-256 supplied through environment variables.

### Release automation

Electrobun release automation is retired with the proof of concept. The root release workflow is intentionally inert until native signing, notarization, archive/export, DMG packaging, and Homebrew release automation are implemented in issue #23.

The old Electrobun release scripts remain in `legacy/electrobun-app/scripts/` only as migration reference material.

### App icon packaging

The source logo lives at `legacy/electrobun-app/assets/icon.png`; the macOS bundle icon lives at `legacy/electrobun-app/assets/App.icns`. A post-build hook (`legacy/electrobun-app/scripts/apply-macos-icon.ts`) copies `App.icns` into the app bundle before codesigning/notarization and updates the bundle plist icon keys. This avoids relying on Electrobun's `.iconset` conversion path, which depends on `iconutil` behavior on the build host.

The webview should not import the full application icon directly for small UI chrome. Use optimized web assets under `legacy/electrobun-app/src/mainview/assets/` such as `app-icon.png`, which is sized for in-app display and emitted by Vite with the rest of the webview assets.

### Fonts and webview assets

The webview bundles product fonts from `legacy/electrobun-app/src/mainview/assets/fonts/` and declares them in `legacy/electrobun-app/src/mainview/index.css`. The UI font is Barlow; code and monospace surfaces use Departure Mono. Because these fonts are bundled into the Vite build, the app does not depend on the user's local Font Book at runtime.

### Main process ⇄ webview RPC

A typed RPC contract lives in `legacy/electrobun-app/src/shared/rpc.ts` (`AppRPC`, built on Electrobun's `RPCSchema`). It's implemented on the main-process side via `BrowserView.defineRPC` (passed into the `BrowserWindow` constructor) in `legacy/electrobun-app/src/bun/index.ts`, and consumed in the webview via `Electroview.defineRPC` in `legacy/electrobun-app/src/mainview/lib/electrobun.ts` (exported as `electroview`). To add a new main-process capability in the legacy app: add the method to `AppRPC.bun.requests`, implement the handler in `src/bun/index.ts`, and call it from the webview via `electroview.rpc.request.<method>()`.

The legacy app RPC includes the agent runtime surface:

- `selectProjectFolder()`: opens a directory picker. Folder selection is optional.
- `selectAttachmentFile()` / `selectAttachmentFolder()`: open single-selection file/directory pickers for the composer's "Add to prompt" menu, independent of the project-folder picker above.
- `prepareAgentSession({ cwd, approvalMode })`: warms up ACP for a selected project folder. By default it starts `devin --permission-mode <mode> acp`; with `LEVEL5_USE_ACP_MOCK=1`, it starts the bundled/repo-local mock server instead. It initializes ACP, creates or reuses a session for the cwd, and lets ACP `configOptions` / `available_commands_update` populate composer controls before the first prompt.
- `startAgentPrompt({ prompt, cwd, model, approvalMode, attachments })`: accepts a non-empty prompt and starts the ACP prompt flow if no turn is already running. `attachments` are sent as `resource_link` content blocks alongside the text block. For Devin, `approvalMode` maps to process flags: `ask` and `auto` use `--permission-mode normal`; `full-access` uses `--permission-mode bypass`.
- `cancelAgentPrompt()`: sends ACP `session/cancel` for the active turn and answers pending permission requests with ACP's cancelled outcome. The composer send button becomes this stop control while a turn is active.
- `respondToAgentPermission({ requestId, optionId })`: answers `session/request_permission` requests that were surfaced to the user (approval mode `ask`, or any request the client could not auto-resolve). Responses use ACP's selected-outcome shape: `{ outcome: { outcome: "selected", optionId } }`.
- `listAgentSessions()`: cold-starts the selected ACP backend once when the webview asks for startup chat history, initializes ACP, calls `session/list`, and returns normalized session summaries. It does not create a new ACP chat session. Later calls reuse the connected process and refresh summaries through ACP.
- `listAgentSlashCommands()` / `listAgentSkills()`: return cached composer menu data. Slash commands come from ACP `available_commands_update`; the Skills group is hidden unless a future agent surface advertises real skills separately.
- `loadAgentSession({ sessionId })`: loads or resumes a known session and replays the cached transcript into the webview.
- `deleteAgentSession({ sessionId })`: deletes a session through ACP and removes the app-side session/transcript cache entry.
- `startNewAgentChat()`: clears the active session selection without terminating the connected Devin process.
- `resetAgentChat()`: clears the current chat and terminates the Devin process if one is running.
- `getProjectGitStatus({ cwd })`: returns non-throwing git summary data for the selected project folder so the webview dashboard can show branch and change counts without spawning processes in React. The main process resolves the repository root with `git -C <cwd> rev-parse --show-toplevel`, reads branch/change state with `git status --porcelain=v1 --branch`, and sums tracked line counts with `git diff --numstat`. Untracked files count toward the changed-file total, but their contents are not read for line totals. Repositories before the first commit are valid: the helper detects missing `HEAD` and diffs against Git's empty tree hash instead of treating the folder as non-git.
- `agentUpdate`: Bun-to-webview message stream used for normalized agent status, messages, plan updates, tool calls, context/usage updates, config options, slash commands, permission requests, session summaries, errors, informational notes, and stop reasons.

The webview should treat `startAgentPrompt` as an acceptance call, not as the whole agent turn. Agent progress arrives asynchronously through `agentUpdate` messages.

### Devin ACP client flow

The legacy app-side workflow is split between a reusable ACP protocol core in `legacy/electrobun-app/src/bun/acp/`, Devin runtime helpers in `legacy/electrobun-app/src/bun/agent/`, and the session adapter in `legacy/electrobun-app/src/bun/index.ts`.

`legacy/electrobun-app/src/bun/acp/` owns the newline-delimited JSON-RPC transport, vendored ACP `v0.11.3` schema validation, typed lifecycle errors, request timeouts, buffered notifications, and the turn idle watchdog. This layer stays provider-agnostic.

`legacy/electrobun-app/src/bun/agent/runtime.ts` owns backend process selection and Devin permission-mode helpers. `legacy/electrobun-app/src/bun/index.ts` contains the session adapter. It:

- detects `devin` on `PATH` and emits a clear install/login error if unavailable;
- spawns Devin as `devin --permission-mode normal acp` for `ask` / `auto`, and `devin --permission-mode bypass acp` for `full-access`;
- skips Devin CLI detection and spawns the mock ACP server when `LEVEL5_USE_ACP_MOCK=1`, using `LEVEL5_ACP_MOCK_START_PATH` as an optional entrypoint override;
- passes `process.env` through so Devin can use CLI login state or environment credentials such as `WINDSURF_API_KEY`;
- initializes ACP with honest v1 client capabilities: no client-side filesystem or terminal capability is advertised;
- sends `initialize`, then `session/new` or `session/load`, then optional `session/set_config_option` for model, then `session/prompt`;
- treats app open as a session-list warm-up: the webview calls `listAgentSessions`, which starts the selected backend once, sends `initialize`, and then calls `session/list` so the sidebar can show persisted chats without waiting for project selection or first prompt. Composer metadata remains lazy: `listAgentSlashCommands` and `listAgentSkills` return cached/empty data until a session is prepared or loaded;
- warms up Devin on project selection through `prepareAgentSession` so model config and slash commands are available before first send;
- when Devin sends `session/request_permission`, `auto` chooses an allow-like option if one is available and emits an informational note; otherwise the request is surfaced to the webview;
- preserves the selected approval mode across process restarts caused by cwd or permission-mode changes;
- watches active prompt turns for inbound ACP activity. If a turn goes silent past the configured idle budget, or if the user hits stop, the adapter sends `session/cancel`, answers pending permission requests with ACP's cancelled outcome, and rejects local pending requests;
- reuses the current session for subsequent prompts in the same cwd;
- closes and recreates the session if the selected folder changes;
- resolves folderless prompts to the user's home directory for ACP `cwd`, while the UI continues to show no selected project;
- keeps an app-side in-memory map of session summaries so the sidebar can show a newly created session immediately after `session/new`;
- keeps an app-side in-memory transcript cache for each known session, including message chunks, plans, tool calls, and the latest usage/context-window update;
- normalizes ACP notifications into webview-friendly `AgentUpdate` messages.

The default prompt idle timeout is 120 seconds and can be overridden for local testing with `LEVEL5_ACP_TURN_IDLE_TIMEOUT_MS`.

Full transcript caches are still in memory and are reset when the main process exits; persisted sessions loaded after relaunch replay through ACP.

### Window chrome

The window is frameless: `titleBarStyle: "hiddenInset"` (native traffic lights, no visible title bar strip, `FullSizeContentView` so the webview covers the whole window). Because the webview covers the title bar area, window dragging has to be opted into explicitly via the `electrobun-webkit-app-region-drag` CSS class (Electrobun's equivalent of Electron's `-webkit-app-region: drag`); any future interactive controls placed over a draggable region need `electrobun-webkit-app-region-no-drag` to stay clickable. The current draggable strip starts to the right of the native macOS traffic lights so close/minimize/zoom remain clickable.

**Known upstream limitation:** Electrobun's window drag is implemented as a custom mouse-tracking move (not the OS's native window-drag/move loop), so dragging to the screen edges or top does not trigger native window tiling/snap the way a normal window would (tracked upstream: [blackboardsh/electrobun#395](https://github.com/blackboardsh/electrobun/issues/395), [#406](https://github.com/blackboardsh/electrobun/pull/406), [#417](https://github.com/blackboardsh/electrobun/pull/417)). As a stand-in, double-clicking the window background calls the `toggleMaximizeWindow` RPC method to fill/restore the screen, mirroring the native "double-click title bar to zoom" convention.

### Text editing keyboard shortcuts

Electrobun's webview does not wire up standard text-editing keyboard shortcuts (`cmd+a`, `cmd+c`, `cmd+v`, `cmd+x`, `cmd+z`, etc.) on its own — on macOS these are dispatched through the app's native menu bar, not raw webview key events. `legacy/electrobun-app/src/bun/index.ts` registers a native Edit menu via `ApplicationMenu.setApplicationMenu([...])` with the standard `undo`/`redo`/`cut`/`copy`/`paste`/`pasteAndMatchStyle`/`delete`/`selectAll` roles at startup so these shortcuts work anywhere text is focused in the webview (the composer, search inputs, etc.). Any new text-editing shortcut needs a corresponding role or explicit `accelerator` added to that menu.
