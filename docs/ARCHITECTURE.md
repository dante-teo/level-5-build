# Architecture

## Native macOS 1.0 direction

[ADR 0001: Native macOS Client for 1.0](adr/0001-native-macos-client.md) defines the accepted migration direction. The native macOS client will take over `app/`, and the current Electrobun proof of concept will move to `legacy/electrobun-app/` during scaffold work.

`acp-mock-server/` remains active shared test infrastructure for the native client and future clients. It must not move into `legacy/` with the Electrobun proof of concept.

## Repo layout

This repo currently hosts:

- `app/`, the native macOS scaffold using SwiftUI, Swift Package Manager modules, Swift Testing, and XcodeGen.
- `legacy/electrobun-app/`, the retired Electrobun proof of concept kept as reference-only migration material.
- `acp-mock-server/`, a standalone Bun/TypeScript Agent Client Protocol mock server for local client and integration testing.
- `script/`, root-level local app run helpers.
- `docs/`, shared architecture/product/design documentation.

The mock server remains usable as a standalone stdio ACP server and protocol fixture. Native runtime integration is still future work; `acp-mock-server/` stays active infrastructure for that work and for CI.

## `acp-mock-server/` — ACP test agent

`acp-mock-server/` is a dependency-light Bun/TypeScript implementation of an ACP v1 agent over newline-delimited JSON-RPC stdio. It is designed for testing client UI and protocol handling without a real model or real code edits.

### Transport and process model

- The protocol entrypoint is `acp-mock-server/start.sh`, which execs `bun src/index.ts`.
- The server reads UTF-8 JSON-RPC messages from stdin and writes only JSON-RPC messages to stdout.
- Logs go to stderr. Do not route diagnostic output to stdout; ACP clients expect stdout to be protocol-clean.
- Session state persists to `.mock-acp-state.json` by default, ignored by git. Override with `ACP_MOCK_STATE_PATH`.
- `runServer()`'s stdin loop dispatches each parsed line without awaiting the previous line's handler to finish. This is load-bearing, not stylistic: a request handler can call back into the client mid-flight (e.g. a prompt turn's `session/request_permission`), and that callback's answer can only ever arrive as a *later* stdin line — if the loop awaited each line to completion before reading the next one, the server would block forever waiting on its own unread response. In-process tests that call `AcpMockServer.handleLine()` directly (`tests/server.test.ts`) can't exercise this class of bug, since they never go through the loop; `tests/subprocess.test.ts` drives the real `bun src/index.ts` entrypoint over an actual stdio pipe specifically to catch it.

### Mocked ACP surface

The mock supports initialization, auth/logout, session lifecycle (`new`, `load`, `resume`, `close`, `list`, `delete`), prompt turns, cancellation, legacy modes, session config options, slash commands, permission requests, model discovery/switching, and mock extension methods under `_mock/*`.

By default, its advertised surface is intentionally Devin-like and app-relevant: visible config is limited to `model`, visible slash commands are `help`, `plan`, `review`, `fix`, and `test`, and mock-only `_mock/*` helpers are callable but not advertised through initialization metadata. `_mock/list_slash_commands` intentionally returns both visible commands and hidden QA commands for direct protocol probing.

Permission requests aren't just a standalone demo path: the edit scenario (triggered by `/fix`, or a prompt containing "edit"/"fix"/"refactor") sends a `session/request_permission` for its simulated diff before applying it, so approval-mode UI can be exercised without needing the literal word "permission"/"approve" in the prompt. A dedicated scenario triggered by those exact words (`permissionScenario`) still exists for direct testing.

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

Model selection is exposed through the ACP-native `configOptions` response (`configId: "model"`, set with `session/set_config_option`) and through direct mock extension methods (`_mock/list_models`, `_mock/set_model`). Slash commands are advertised with `available_commands_update` so autocomplete and command-palette UI can be tested without adding real agent logic. Hidden prompt phrases such as `fail`, `refuse`, `max tokens`, `permission`, and `web` / `fetch` still exercise QA edge states without appearing in the visible slash-command menu.

### Manual testing with the legacy app

The retired Electrobun app does not use the mock server for normal chat/session work unless `LEVEL5_USE_ACP_MOCK=1` is set. The convenient manual command for inspecting that legacy behavior is:

```bash
cd legacy/electrobun-app
bun run dev:mock
```

Use `./start.sh` from `acp-mock-server/` when manually testing protocol behavior outside the app.

Mock-mode app runs use `~/.level5-build/acp-mock-state.json` for state unless `ACP_MOCK_STATE_PATH` is set. Set `LEVEL5_ACP_MOCK_INDEX_PATH` to an absolute `acp-mock-server/src/index.ts` path when testing a custom mock checkout instead of the bundled or repo-local copy.

### Verification

From `acp-mock-server/`:

```bash
bun test
bunx tsc --noEmit -p tsconfig.json
```

From the repo root:

```bash
bash -n script/build_and_run.sh
bash -n acp-mock-server/start.sh
```

Use `./start.sh` for ACP stdio smoke tests instead of `bun run`; some Bun script invocations echo command banners before process output, which would pollute ACP stdout.

## `app/` — native macOS app

Stack: SwiftUI for the app shell, Swift Package Manager for module layout and command-line tests, Swift Testing for tests, and XcodeGen for the generated Xcode project. The generated `.xcodeproj` is local build output and is not committed.

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
│   └── Level5Core/
└── Tests/
    ├── Level5BuildAppTests/
    └── Level5CoreTests/
```

`Level5Core` is the provider-neutral module where reusable runtime/domain code will grow. `Level5BuildApp` is the SwiftUI app target. The current UI is intentionally a minimal native shell; full workspace layout, ACP runtime, persistence, signing, notarization, and packaging are follow-up work.

### Build / dev flow

From `app/`:

```bash
xcodegen generate --spec project.yml --project .
swift test
xcodebuild test \
  -project "Level5 Build.xcodeproj" \
  -scheme "Level5 Build" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

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
- skips Devin CLI detection and spawns the mock ACP server when `LEVEL5_USE_ACP_MOCK=1`, using `LEVEL5_ACP_MOCK_INDEX_PATH` as an optional entrypoint override;
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
