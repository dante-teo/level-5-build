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

`Level5Core` is the provider-neutral module where reusable runtime/domain code will grow. It owns recent-project persistence, native project Git status, and provider-neutral ACP primitives. `Level5Design` owns reusable SwiftUI design primitives, semantic tintable in-app icon APIs, and bundled in-app identity/font resources. `Level5BuildApp` is the SwiftUI app target.

`Level5Core`'s ACP layer is intentionally hand-coded and tolerant rather than generated from a full schema. It includes reusable `Codable` protocol values, JSON-RPC envelopes, method constants, a newline-delimited JSON-RPC transport actor, a thin `AcpClient`, and a generic `AcpProcessTransport` wrapper around native `Process`. Unknown forward-compatible fields are tolerated where possible; required identifiers and discriminators remain strict. This keeps the core provider-neutral while covering the ACP surface the native app and mock tests currently need.

`Level5Core.ProjectGitStatusService` is also provider-neutral. It shells out only through native `Process`, never from SwiftUI views, and returns a non-throwing unavailable status if Git cannot be queried. Each Git command has a short timeout. Status collection follows the current product contract: discover the repository root with `git -C <cwd> rev-parse --show-toplevel`, parse `git status --porcelain=v1 --branch`, resolve detached `HEAD` to a short SHA, and sum text line changes with `git diff --numstat <base> --`. Repositories with no commits diff against Git's empty tree. Untracked files count toward changed-file totals, but their contents do not count toward line totals; binary numstat rows are ignored.

`Level5Core.ProjectReviewService` is the source of truth for the native Review pane. Review is Git working-tree based and inspect-only: it shells out to `git`, excludes ignored files through normal Git visibility, and never stages, discards, commits, reverts, answers permissions, or mutates approval state. It discovers the repository root from the selected project/session cwd, snapshots uncommitted files from `git status --porcelain=v1 --branch --untracked-files=all`, sorts by display path, caps rendered rows at 500, and exposes overflow separately. Snapshot and preview paths are repository-root relative, so selecting a subdirectory inside a Git repository still previews the correct files; untracked directories are expanded to file rows by Git rather than treated as directory previews. File previews are lazy: tracked files use a combined `HEAD` (or Git empty tree before the first commit) to working-tree unified diff; untracked text files synthesize a new-file diff; binaries and nested repositories/submodules show metadata only; symlinks are treated as textual targets and are never followed; per-file previews over 200 KB return a deterministic too-large state. Git failures surface a friendly message plus raw details for disclosure.

The current app UI is a native shell. `ContentView` owns window-scoped shell state and composes:

- `ShellSidebarView` for New Chat, durably-cached session rows, fixed trailing state indicators, and confirmed context-menu delete actions.
- `WorkspaceView` and `TranscriptView` for the empty new-session state plus compact rendering of the active structured transcript.
- `ComposerView` for native prompt drafting, file attachments, model selection, approval-mode selection, slash-command insertion, permission-request takeovers, backend unavailable state, and the visible per-session queue.
- `AgentSessionModel` for app-private session lifecycle, transcript caches, per-session queues, backend availability, and ACP event routing.
- `ShellCommands` for scene-level menu commands routed through focused values.

Backend selection is explicit and layered. In DEBUG builds only, `LEVEL5_USE_ACP_MOCK=1` selects the repo-local ACP mock backend; release/Homebrew-style builds ignore mock env vars. Otherwise `DevinRuntime` scans `$PATH` plus known install directories (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) for a `devin` executable and, if found, selects the real Devin backend. If neither is available, agent actions are disabled and the composer shows product UI for "Agent runtime unavailable" with an actionable install/auth message; the active app path never appends fake local placeholder responses.

In mock mode, the app connects to the independently running TCP mock server through `Level5Core.AcpClient` and initializes ACP. There is no ACP `session/list` call anywhere in `AgentSessionModel`: the sidebar is sourced entirely from the durable local session cache (see Durable session/transcript persistence below), using provider `updatedAt` plus app-observed activity for recent-first ordering. A session this app never sent through — another client, another machine, or one lost to a crash before its first persisted write — is permanently invisible in the sidebar. New Chat is only an unsent draft: it creates no hidden ACP session and appears in no sidebar row until first send. First send calls `session/new`, inserts/selects the row, appends the user prompt when the turn starts, then sends `session/prompt`. Selecting an existing row is pure retrieval: it paints that session's durably cached transcript synchronously and does not talk to the agent runtime at all — no `ensureConnected`, no `session/load`. Server-side context is instead primed lazily, the moment a session that this process hasn't already primed this run is actually sent to: that first `send` calls `session/load` first, adopts its session model config, and only then sends `session/prompt`; any `session/update` replay the load triggers as a side effect is unconditionally suppressed rather than applied, since priming is a context-loading call, not a way to repaint history. A session created or already primed earlier in the same process run is sent to directly, with no repeated `session/load`. Selection is not activity for sidebar ordering; live user/agent chunks sent or received are activity and can move the row. Delete is exposed only from a row context menu, requires native destructive confirmation, calls `session/delete` best-effort, and returns to New Chat when the active session was deleted.

In Devin mode, `AgentSessionModel` supervises one spawned `devin --permission-mode <mode> acp` process per project directory rather than a single shared connection, keyed by normalized project path (a synthetic key covers the home-directory fallback when no project is selected). This gives true concurrent sessions across different projects: each project's client has its own event stream, ACP client generation counter, and turn/permission state, so one project's process exiting, timing out, or streaming events cannot leak into another project's transcript. The same isolation applies to the global `availability`/`runtimeMessage` status banner and to `activeSessionId`: these are singleton, foreground-scoped properties gated by `isActiveProjectKey`, reflecting only the active session's project (or the selected "new chat" project when none is open). A background project's connection failure, turn completion, permission event, or idle-timeout cancellation updates only that project's own sidebar rows (`isRunning`, `isAwaitingPermission`, `hasCompletedTurn`); it must never overwrite the banner or reset the session the user is currently viewing. Selecting a "new chat" project eagerly connects that project's process; the sidebar itself is already a single global list of every project's persisted rows hydrated once up front (there is no backend session list to pull from — see "Durable session/transcript persistence" below), so selecting a project changes only where a new session would be created, never which rows are visible or evicted. Because a no-op reconnect to an already-healthy project doesn't otherwise touch the global status banner, switching to it also immediately resets `availability`/`runtimeMessage` to reflect that project's own healthy connection, so a stale in-flight message left behind by whichever project previously held the foreground (e.g. a background send's "Sending...") cannot keep showing for the newly foregrounded one. Approval-mode changes restart the affected project's process with a new `--permission-mode` flag rather than trying to change it live: empirically, the ACP `session/set_mode` method only affects the agent's Normal/Plan/Ask conversation mode, not tool-approval enforcement, so there is no reliable in-place way to change permission enforcement for a running process. If a project has a turn in flight when approval mode changes, the restart is deferred until that turn completes so in-flight work is never killed. Because Devin has no request/response API for listing models or slash commands outside of a session, `AgentSessionModel` derives them from the `session/new`/`session/load` result's `configOptions` and from live `session/update` notifications (`config_option_update`, `available_commands_update`) instead of the mock-only `_mock/list_models` / `_mock/list_slash_commands` extension methods. Both `session/new` and `session/load` require an (even empty) `mcpServers` array in their params for real Devin, or the call is rejected outright; `session/load` also requires `cwd`, without which it fails with a "missing field cwd" deserialization error — this matters specifically for reconnecting to a session a *different* (e.g. previous-launch) process created, since that's the one case where this process has no other way to know which project's session it's loading.

Killing a project's process — an approval-mode restart, or app quit — always closes every session that process created or primed first (`AgentSessionModel.closeSessionsAndTerminateClient`, best-effort: a backend that can't close cleanly, or doesn't implement `session/close`, must not block teardown). Real Devin refuses a future `session/load` for any session a still-live process holds open with "Session '…' is already open in another process. Close the other instance before opening it here.", so simply killing the process without this handshake would permanently orphan every session it had open — including from that process's own next relaunch. There is otherwise no `AppDelegate` by default in a SwiftUI `App`; `Level5AppDelegate` (`@NSApplicationDelegateAdaptor` in `Level5BuildApp`, bridged into the environment since it conforms to `ObservableObject`) exists solely to give `AgentSessionModel.prepareForTermination` a chance to run before the app process actually exits, via two independent paths: `applicationShouldTerminate` returning `.terminateLater` and replying once cleanup finishes (a graceful Cmd+Q/Dock quit), and `SIGTERM`/`SIGINT` `DispatchSourceSignal` handlers that run the same cleanup outside that lifecycle entirely — needed because `script/build_and_run.sh` restarts the app with `pkill -x`, a raw signal that bypasses `applicationShouldTerminate` altogether.

Because a fresh "new chat" composer would otherwise show no models/slash-commands/skills until the user's first send, `AgentSessionModel` primes it eagerly: as soon as a project's client connects (app launch for the home directory, or `selectProject`/`clearSelectedProject`), it silently calls `session/new` to populate real config/commands, without creating a visible sidebar row. The first real send reuses that primed session instead of creating another one. Real Devin's ACP server does not handle that composer-priming `session/new` racing an unrelated `session/load`/`session/prompt` against the same process safely, and project selection is not restored across launches, so `start()` always eagerly primes the home-directory key on every launch regardless of what the user does next — selecting an already-restored home-directory session and sending immediately after launch would otherwise race that priming. `AgentSessionModel.awaitComposerPriming`, backed by `primingTaskByProjectKey` (the task `start()`/`selectProject`/`clearSelectedProject` create), sequences `send`/`createSessionAndSend` after any in-flight priming for the same project key finishes rather than letting them run concurrently. This is safe because Devin only persists a session to its own session store after its first message — an abandoned priming session (e.g. the user switches projects before sending) is never written to disk and never appears anywhere this app could discover it. Selecting an *existing* sidebar session never connects or calls `session/load` — it only paints that session's durably cached transcript. `session/load` survives in the codebase solely as a send-time priming call: the first time a process run is about to send into a session it hasn't already created or primed this run, it loads that session's server-side context first (real Devin also requires `mcpServers` and `cwd` here — the latter is always the project's own key, since a project's key *is* its normalized cwd), applies the returned config, and only then prompts; a session created or primed earlier in the run is sent to directly. Any `session/update` notification `session/load` triggers as a side effect is unconditionally dropped rather than applied — it is a context-loading side effect, never a transcript source — so the durable cache and the live transcript can never be corrupted by a priming replay. If priming fails, the send is aborted before any optimistic user row is appended or turn is started, and a "Load failed" error is shown instead. Both the "already primed" bookkeeping and the drop-in-flight-replay marker are scoped per project and cleared whenever that project's client is torn down (approval-mode restart, idle timeout, process exit) alongside the rest of that project's connection state, so a session primed before a restart is transparently re-primed on its next send, and a prime still in flight against the now-dead client cannot leave a later, legitimate `session/update` suppressed once the project reconnects.

Known Devin ACP gap: `session/delete` is not implemented by the real agent (`Method not found`), unlike the mock server, and the backend would keep the session around forever if it could still be listed. Sidebar deletion does not require server agreement to work: `AgentSessionModel.deleteSession` calls `session/delete` best-effort and removes the session locally either way, then durably remembers the deletion (see Durable session/transcript persistence) so the row cannot resurrect from a later background `session/update`, on Devin or any other backend that can't (or doesn't) forget it server-side.

Known accepted regressions from removing all backend session discovery: a session created by another client (or another machine, or lost to a crash before its first persisted write) is permanently invisible in this app, since there is no `session/list` call anywhere to discover it. If send-time priming fails because the backend truly has no record of a session, that conversation cannot be continued from this app — the user has to start a New Chat.

The native lifecycle model permits multiple sessions across multiple projects to have running turns concurrently, but only one active turn per session. Running state is tracked by per-session active-turn records, not a global boolean: each record has a local turn ID, the ACP client generation (scoped per project) that owns its event stream, a watchdog, and the latest inbound activity timestamp. Sending again while the active session is running queues an immutable structured composer snapshot in that session's in-memory FIFO queue. Queued prompts render compactly above the composer and can be removed before they start. Queued prompts move into the transcript only when they begin sending. If a queued prompt fails, the model records an error row and continues to later queued prompts.

The composer draft is an app-private value model. It stores text segments, accepted slash-command tokens, selected model, and up to 10 deduped standardized file attachment URLs. Attachments are not read by the client; prompt serialization sends one ACP text block when serialized text is non-empty followed by `resource_link` blocks with `file://` URIs and basename names. Empty text with attachments is valid; empty text with no attachments is not sent. The editor starts at one text line, grows from measured `NSTextView` content, and caps at 12 lines before the scroll view handles overflow.

ACP model and slash-command discovery is backend-driven. On startup, mock mode initializes ACP and calls the mock discovery extensions (`_mock/list_models` and `_mock/list_slash_commands`) so New Chat can render the selector and command menu before first send. Session load/create reads model config from ACP `configOptions` where `id == "model"` and treats backend config updates as authoritative unless a local model change is in flight. Existing-session model changes call `session/set_config_option`, update the selector optimistically, and roll back with a composer status error on failure. Rollbacks are scoped by session id, so reconnect failures clear the pending save state and async failures after a session switch do not mutate the visible draft for a different session. First send applies a pending New Chat model only when it differs from the session's reported model, then sends the structured prompt blocks.

Approval mode is app-private state owned by `AgentSessionModel` and persisted per backend in `UserDefaults`. The supported modes are `Ask for approval`, `Approve for me`, and `Full access`. `Ask for approval` stores parsed ACP `session/request_permission` requests by `sessionId`; pending requests for the visible session replace the composer with a permission takeover, while background-session requests leave the active composer usable and mark the relevant sidebar row as awaiting approval. `Approve for me` currently auto-selects an allow-like option for the mock backend, falling back to the first backend-provided option, and records a compact status note (never rendered as a transcript row — see "Transcript rendering" below). `Full access` uses the same allow-like fallback without a status note. Permission responses are explicit selected-option replies: `{ "outcome": { "outcome": "selected", "optionId": "<id>" } }`. Cancelled permission requests use ACP's cancelled outcome: `{ "outcome": { "outcome": "cancelled" } }`. Reject-with-instructions chooses a reject-like option if available, otherwise the last option, then sends the typed instructions as the next prompt for that same session through the existing per-session queue/send path; the instruction text is not serialized into the ACP permission response.

`Level5BuildApp` owns an app-private structured transcript layer:

- `AgentTranscriptEvent` is the normalized event stream from ACP updates and prompt outcomes.
- `AgentTranscriptReducer` is pure and deterministic, merging message chunks by `messageId`, falling back to contiguous same-role message merging when no ID exists, storing structured plan state, merging tool updates by `toolCallId`, tracking latest usage metadata, and storing every stop reason.
- `AgentTranscriptState` is held per `sessionId` by `AgentSessionModel`. It stores ordered transcript items plus active plan state, latest usage, latest error, tool expansion state, and stop-reason metadata.
- `AgentTranscriptNormalizer` converts tolerant raw ACP `session/update` JSON into transcript events while preserving unsupported non-text content as unsupported-block counts. Unsupported-only message blocks keep empty text and render from that count so the UI does not duplicate placeholder text.

Transcript rendering is intentionally compact. User and agent messages render as chat rows, with message bodies rendered as Markdown (bold/italic, inline code, links, lists, headings, blockquotes, code blocks) via `Level5BuildApp.L5MarkdownTheme`, a `MarkdownUI` theme built from `Level5Design`'s `L5Font`/`L5Color`/`L5Spacing`/`L5Radius` tokens, rather than as raw unstyled text. Plan and usage updates do not render transcript rows: the active session's plan renders as a centered composer-adjacent `Plan N/M` chip with a checklist popover, while usage renders only as the context ring immediately left of the model selector. Tool and error items render as operational transcript rows with normalized human-readable content only; tool rows auto-expand while `in_progress`, auto-collapse when `completed` unless manually expanded, and remain expanded when `failed`. Expanded tool rows expose a small normalized detail area for status, kind, and readable detail text; collapsed rows keep a one-line preview. `.status` items (runtime diagnostics, raw stderr, permission audit notes, notable stop reasons like `cancelled`/`refusal`/`max_tokens`) are recorded in `AgentTranscriptState.items` and persisted like any other item, but `AgentTranscriptState.renderableItems` unconditionally filters them out — they are never shown as transcript rows, full stop, regardless of source. Ordinary `end_turn` stop reasons don't even reach `items`: they're stored purely as metadata (`stopReasons`). Terminal panes and raw JSON inspection remain out of transcript scope; Git diff rendering lives in the Review column.

The context ring appears only when positive `used` and `size` usage values are present for the active session. It animates progress and color changes, uses accent below 70%, warning from 70%, and danger from 90%, and disables pulse-style motion when Reduce Motion is enabled. Its hover/focus/click popover shows percent used, tokens left, used/size tokens, and optional cost.

Project-backed active sessions expose an adaptive project dashboard. A session is project-backed only when it came from an explicit selected recent project, or — for Devin, whose per-project key already *is* its normalized cwd (see `projectKey(for:)`) — when a session hydrated from the durable cache on a later launch has a `projectKey` matching a persisted recent project; mock's single shared project key never matches a real path, so this second path never applies there. This eligibility check isn't tied to hydration order: `hydrateAllPersistedSessions` records every hydrated session's cwd unconditionally, and `reconcileSessionProjectPaths()` (invoked whenever `setRecentProjects` runs) is what actually decides project-backed status from that cwd, so a session hydrated before recents are known (e.g. `ContentView.selectProject(_ url:)` hydrates before its own recents reload resolves) still becomes correctly project-backed once recents catch up moments later. The home-directory fallback used for folderless mock sends is not project-backed, and backend `cwd` values are not auto-added to recent projects. The dashboard is shown for project-backed sessions even when the folder is not a Git repository; non-Git folders render project metadata with unavailable Git status.

Dashboard state is event-driven and in memory with the active transcript state. `AgentSessionModel` refreshes it on project/session changes, dashboard visibility changes, send/end-turn/activity edges, and explicit refresh actions. It does not use filesystem watchers or polling. Async Git refreshes carry a generation token so stale results after a session or project switch are ignored.

Review state is also in memory and window-scoped. It is available for New Chat when a project is selected and for project-backed active sessions. Opening Review refreshes the full snapshot and renders a continuous top-to-bottom diff document, one changed file section after another, without a separate file-list selection step. File previews load lazily as their sections appear and are cached for the current snapshot only. The Review toggle is hidden unless the window can fit the minimum workspace, the resize handle, and the default Review column width, including after sidebar collapse. Turn completion and cancellation refresh lightweight Review counts even while the pane is closed so Review availability stays current. Project-context changes close Review and invalidate in-flight refreshes/previews through generation checks.

Dashboard references are derived best-effort from ACP tool content, locations, `_meta`, and `metadata` because ACP does not currently expose a first-class sources contract. Web URLs and local files outside the active project root are retained; project-local file reads are filtered out to avoid noisy source lists. References dedupe by stable identity (`kind` plus `uri`) rather than title, preserving the first title seen so duplicate metadata cannot produce duplicate SwiftUI row IDs.

Transcript auto-scroll is per-session follow-tail state. Sessions follow the tail by default; user scroll-up disables auto-follow for that session, and scrolling back to the bottom re-enables it. Reselecting a session preserves its existing follow-tail state instead of forcing a jump to the bottom. This is intentionally in-memory only and does not survive a relaunch, unlike the durable transcript cache described below.

`TranscriptView` renders rows with SwiftUI but uses SwiftUI Introspect to access the backing macOS `NSScrollView` for scroll state. The controller derives "at bottom" from the actual document bounds, visible rect, viewport height, and AppKit flipped-coordinate behavior; content changes settle to bottom only while the session was already following the tail. Wheel, trackpad, scrollbar-drag, and key-scroll input cancel any pending programmatic settle so manual reading is not fought by streaming updates.

The session model appends an optimistic local user row only when a prompt actually starts. It tracks pending backend user echoes per session so replayed/streamed backend echo chunks can be suppressed. If a prompt fails before its backend echo arrives, the pending optimistic echo entry is removed so later successful prompts cannot duplicate user rows. After manual Stop, the pending echo queue is also the handoff signal for immediate re-prompts: late cancelled-turn output stays suppressed until the backend echoes the new prompt's user message, then live output for that session is accepted again.

ACP event handling routes updates by `sessionId`, handles structured transcript events, session title/timestamp updates, diagnostics, stderr, process exits, and policy-driven permission requests. Raw stderr lines from the runtime process and its tool subprocesses are pre-filtered by `AcpRuntimeLogLine.isWorthRecording` before becoming a `.status` item at all: routine structured `tracing`-style `TRACE`/`DEBUG`/`INFO` lines (the vast majority of stderr volume) are dropped outright, while `WARN`/`ERROR` lines and anything that doesn't match the structured format (a raw panic/crash) are still recorded. Since `.status` items are never rendered as transcript rows regardless of source (see "Transcript rendering" above), this filter's only effect today is bounding how much noise accumulates in in-memory transcript state and the durable SQLite cache — it does not affect what, if anything, a user ever sees for a given stderr line. Manual Stop is treated as normal ACP cancellation for the selected active session: the model immediately marks that turn stale, restores composer editing, clears queued prompts for that session, sends `session/cancel`, cancels any pending permission request, preserves transcript content already streamed, suppresses late output from that stale turn, and keeps a healthy ACP connection alive. The stale marker is not cleared just because a new prompt starts in the same session; it clears only when the backend echo for that new prompt completes, preventing cancelled-turn output from leaking into an immediate re-prompt. Idle timeout and process exit are treated as unhealthy runtime recovery paths: active turns and permission state are cleared, the old ACP generation is invalidated, a transcript error/status is appended, the client is reset, and the next user action reconnects. This idle-activity watchdog — not a fixed request-level timeout — is the sole mechanism for detecting a genuinely stuck turn: `AcpClient.prompt` (`session/prompt`) uses its own generous (6h) timeout override rather than the transport's short (10-30s) default meant for quick RPCs, since a real tool-using turn's `session/prompt` call legitimately doesn't resolve until the entire turn completes. Binding it to the short default previously caused a reproduced-in-production bug: the request timed out and got reported as "Prompt failed" while the agent kept working, its `session/update` notifications (and even the eventual real `session/prompt` response) still arrived but the response now belonged to a request nothing was waiting on anymore, logged only as an "unexpected response id" diagnostic and otherwise silently dropped — from the user's perspective the reply appeared to never render even though the underlying transcript data was never actually wrong. The default idle timeout is 120 seconds and can be overridden with `LEVEL5_ACP_TURN_IDLE_TIMEOUT_MS`; watchdogs pause while their session is waiting on human permission, including background-session permission requests. Sidebar state precedence is awaiting permission, running, successful completion, then idle; successful completion is set only after `end_turn` and clears on next activity in that session.

### Durable session/transcript persistence

`Level5Core.Level5Database` owns the single `DatabaseQueue` connection and single `DatabaseMigrator` for the ADR-mandated SQLite file at `~/.level5build/level5.sqlite`; GRDB recommends one writer connection per file, and two independent `DatabaseQueue`s to that file would work but buy nothing. Each store still defines and owns its own named migrations as locality-preserving `static` arrays (`RecentProjectStore.migrations`, `SessionPersistenceStore.migrations`); `Level5Database` only composes them into one explicit, ordered list at construction. `RecentProjectStore` accepts an injected `Level5Database` (or, via a convenience initializer that opens its own scoped `Level5Database`, a bare `databaseURL`) instead of always opening its own queue. `ContentView` builds one shared `Level5Database` and hands it to both `RecentProjectStore` and `SessionPersistenceStore` by default; callers that want no on-disk persistence (tests) pass `nil` for both stores explicitly.

`Level5Core.SessionPersistenceStore` is provider-neutral and shape-agnostic about transcript internals: it only ever sees `(kind: String, payload: Data)`, so it stays reusable by a future non-GUI client. Three tables back it: `sessions` (one row per known session — `sessionId`, `projectKey`, `backend`, `title`, `detail`, `providerUpdatedAt`, `observedAt`, `createdAt`, indexed on `(projectKey, observedAt)`); `session_transcript_items` (ordered per-item rows — messages/tools/statuses/errors — keyed by the same stable ids the in-memory reducer already uses, `UNIQUE(sessionId, itemId)`, ordered by autoincrementing `id` so upserts preserve first-insertion order without an app-maintained sequence counter); and `session_transcript_state` (one row per session for the singleton plan/usage/stop-reasons/references JSON fields that aren't an ordered list). Transcript tables reference `sessions(sessionId) ON DELETE CASCADE` (GRDB enables `PRAGMA foreign_keys` by default), so `deleteSession` alone removes every row for a session. Explicitly not persisted: `isRunning`/`isAwaitingPermission`/`hasCompletedTurn` (live turn-state, correctly reset to false after a relaunch) and per-tool manual expand/collapse overrides (reset to the default expand-while-running/collapse-when-done heuristic after a relaunch).

`Level5BuildApp.TranscriptPersistenceCoding` owns the encode/decode boundary: small `Codable` DTOs mirroring `AgentTranscriptMessage`/`Tool`/`Status`/`Error`/`AgentPlanState`/`AgentTranscriptUsage`/`[AgentReference]`, plus pure mapping functions to/from `AgentTranscriptState`. `AgentTranscriptReducer` stays pure/IO-free; all persistence awareness lives in `AgentSessionModel`, which holds an injectable `persistenceStore: SessionPersistenceStore?` (`nil`/fake in tests, matching the `approvalModePreferenceStore` pattern).

On `start()`, `AgentSessionModel.hydrateAllPersistedSessions` synchronously loads *every* persisted session row, across every project, into the sidebar in one pass. The sidebar is a single global list independent of whichever project is currently selected for the next new chat: selecting a different "new chat" project (`selectProject`/`clearSelectedProject`) only changes where a new session would be created, and re-runs the same unscoped hydration defensively (cheap and idempotent) rather than narrowing the sidebar to that project's rows. This is not a cold-start paint waiting to be overwritten — there is no ACP `session/list` call anywhere, so the durable cache is the sidebar's only source, full stop. A full hydration pass goes through `upsert`, the same write-through every live update uses. Pruning is delete-only: a row absent from the current hydration pass is never removed from disk, only an explicit `deleteSession` removes it.

Deletion does not require the backend's agreement. `deleteSession` calls the ACP `session/delete` RPC best-effort — its failure (or the client being unreachable) does not block anything, because some backends (real Devin) don't implement it at all — then unconditionally removes the session's in-memory state, evicts its cached rows from `SessionPersistenceStore`, and records the id in a small durable `hidden_sessions` table (`SessionPersistenceStore.markSessionHidden`/`.hiddenSessionIds()`, loaded into memory once at `AgentSessionModel` construction). Every path that could otherwise resurrect a row — a background `session/update`'s `session_info_update` fallback, and `ensureSessionRowExists` for a lingering permission request — is filtered against that hidden set, so a session the user deleted locally stays gone even if the ACP server keeps reporting or streaming updates for it, and even across a relaunch.

Selecting a session synchronously hydrates its cached transcript from disk and that is the entire operation: it never calls `session/load` or even `ensureConnected`, so switching into (or relaunching into) a session paints instantly instead of flashing empty, with no dependency on the agent runtime at all. Server-side context is fetched lazily instead, the moment the user actually sends into a session this process run hasn't already created or primed: `send` calls `session/load` first (see above), and any `session/update` notification that load triggers as a side effect is unconditionally dropped by `handleSessionUpdate`, before it can ever reach `apply(_:to:)` or the durable cache. This is a stronger guarantee than "discard cache, then trust replay": priming is never a transcript source at all, so there is no reset-then-repaint window and no risk of a priming replay duplicating or corrupting cached content. If the backend never responds to a live send (disconnected/unavailable), the hydrated cache simply stays displayed — graceful degradation, no special-case code needed.

Writes are not debounced. Every `apply(_:to:)` call touches only the one or two transcript rows the event actually changed — ids driven by an explicit `messageId`/`toolCallId`/`replacementKey` are deterministic, and the reducer's two "no explicit id" paths (message merge/append with no `messageId`, status/error append with no `replacementKey`) always land on the trailing item — and writes them via `Task.detached(priority: .utility)` off the main actor. This avoids a wall-clock debounce's complexity (an injectable clock, a termination-flush path) for a write volume that is already granular; revisit only if profiling shows it matters at fast token-streaming rates. `upsert(_:)` for sidebar rows write-throughs to the `sessions` table inline instead, since those writes are cheap and infrequent (same style `RecentProjectStore` already uses).

Corruption and versioning degrade gracefully rather than erroring. A bad JSON payload on a single cached transcript row is caught by `TranscriptPersistenceCoding.decode`/`.apply` and that row is simply skipped (a cache miss), never aborting the rest of hydration; `SessionPersistenceStore` itself never trusts a raw `Row` subscript that could trap on a type mismatch; a row it cannot decode is deleted so it cannot repeatedly fail. `payloadVersion` mismatches are treated as a cache miss, not an error, since this is a cache and not the source of truth — no migration logic is needed for the transcript payload shape itself. Store construction is `try?`-tolerant at the `ContentView` level, same as `RecentProjectStore` today: failure to open the database disables persistence, not the app.

Non-goals: queued/unsent prompts, composer drafts, and manual tool-expansion overrides are not persisted across a relaunch; there is no retention/eviction cap on cached sessions/transcripts yet; there is no cross-device/cloud sync.

### Native project context

The native app supports local project context selection only in the new-session composer footer. The selected project is window-local `AgentSessionModel` state (`selectedProject`, on the `@State` instance `ContentView` owns), is not restored on launch, and becomes locked once a session is active because `isProjectSelectionAvailable` mirrors `isNewSession`, which `selectProject`/`clearSelectedProject` both guard on. Starting a New Chat clears the draft/transcript and makes project selection available again while preserving the current window-local project selection.

The same footer also shows the selected project's current Git branch once fetched. `AgentSessionModel.selectedProjectBranch` is deliberately separate state from the active-session dashboard's `dashboardState.gitStatus.branch`: it tracks `selectedProject` (the project chosen for the *next* new chat) rather than `activeSessionProjectPath`, is refreshed through the same provider-neutral `gitStatusProvider` on every `selectProject`/`clearSelectedProject` call, and uses its own `selectedProjectBranchRefreshGeneration` counter to discard a stale in-flight fetch if the selection changes again before it resolves. It is `nil` — hiding the footer's branch chip entirely rather than showing a stale or placeholder value — whenever no project is selected or Git status comes back unavailable.

Recent project folders are persisted by `Level5Core.RecentProjectStore` with GRDB, sharing the `Level5Database` connection described above at `~/.level5build/level5.sqlite` for runtime. Tests must inject a temporary database (or database URL). The `recent_projects` table uses the normalized absolute path as its primary key and stores `displayName`, `createdAt`, and `lastOpenedAt`.

Path normalization uses `URL(fileURLWithPath: path).standardizedFileURL.path`; it does not resolve symlinks. Any existing directory is a valid project folder, regardless of Git/package metadata. Upserting a selected folder updates `lastOpenedAt`, keeps the original `createdAt`, and prunes the table to the 10 most recently opened projects. Missing paths are not deleted automatically; the picker displays them disabled and lets the user remove them.

The selected project path is exposed as local shell state. In mock mode it is used as ACP `cwd` for first send from New Chat; folderless mock prompts use the home directory. Selecting an existing session does not touch its cwd at all — selection is pure local retrieval and never talks to the agent runtime (see above); a session's cwd is fixed at creation time and only a future backend-initiated cwd update (if a backend ever sends one) could change it.

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

In-app chrome should not consume generated app-icon artwork or separate raster icon sets. Product-level UI concepts should use `Level5Design.L5Icon` / `L5IconView`, which centralizes SF Symbol selection and keeps icons vector, tintable, and consistent with native macOS controls. File-type glyphs, chevrons, and backend-provided command symbols may remain local SF Symbols where their meaning is control-specific.

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
- Legacy release scripts and stable Electrobun package commands are retained only as migration reference material. Do not use them for new Level5 Build releases.

### Release automation

Electrobun release automation is retired with the proof of concept. Native releases are handled by the root `.github/workflows/release.yml` workflow, which builds the Xcode app target, signs with Developer ID, notarizes and staples the app and DMG, publishes GitHub Release artifacts, and updates the stable Homebrew cask. See `docs/RELEASE.md`.

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
