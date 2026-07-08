# Architecture

## History: native macOS detour, now reverted

[ADR 0001: Native macOS Client for 1.0](adr/0001-native-macos-client.md) moved the app to a native Swift/SwiftUI client for a time. [ADR 0002: Revert to Electrobun](adr/0002-revert-to-electrobun.md) superseded it and has since been fully implemented: the native Swift scaffold was deleted, and the Electrobun/React app (previously kept at `legacy/electrobun-app/` during the migration window) was promoted to `app/` — the shipped path described in this document. There is no more native macOS client, and `legacy/` no longer exists in this repository. See ADR 0002 for the historical rationale and migration sequence.

`acp-mock-server/` remained active shared test infrastructure throughout that migration and stays that way now.

## Repo layout

This repo currently hosts:

- `app/`, the Electrobun/React desktop app — see "`app/` — the Level5 Build app" below.
- `acp-mock-server/`, a standalone Node/TypeScript Agent Client Protocol mock server for local client and integration testing.
- `docs/`, shared architecture/product/design documentation.

The mock server remains usable as a standalone stdio ACP server and protocol fixture, and as a backend the app spawns directly over stdio when `LEVEL5_USE_ACP_MOCK=1` is set (see below).

## `acp-mock-server/` — ACP test agent

`acp-mock-server/` is a dependency-light Node/TypeScript implementation of an ACP v1 agent over newline-delimited JSON-RPC stdio. It is designed for testing client UI and protocol handling without a real model or real code edits.

### Transport and process model

- The protocol entrypoint is `acp-mock-server/start.sh`, which builds stale or missing TypeScript output with Bun and execs Node.
- The server reads UTF-8 JSON-RPC messages from stdin and writes only JSON-RPC messages to stdout.
- A TCP-wrapped entrypoint, `acp-mock-server/start-tcp.sh`, exposes the same mock lifecycle over TCP on `127.0.0.1:58945` by default for manual testing outside a stdio pipe; `app/` does not use it (it spawns the mock server directly over stdio, see below).
- Logs go to stderr. Do not route diagnostic output to stdout; ACP clients expect stdout to be protocol-clean.
- Session state persists to `.mock-acp-state.json` by default, ignored by git. Override with `ACP_MOCK_STATE_PATH`.
- `runServer()`'s stdin loop dispatches each parsed line without awaiting the previous line's handler to finish. This is load-bearing, not stylistic: a request handler can call back into the client mid-flight (e.g. a prompt turn's `session/request_permission`), and that callback's answer can only ever arrive as a later stdin line. If the loop awaited each line to completion before reading the next one, the server would block forever waiting on its own unread response. In-process tests that call `AcpMockServer.handleLine()` directly (`tests/server.test.ts`) can't exercise this class of bug, since they never go through the loop; `tests/subprocess.test.ts` drives the real `start.sh` entrypoint over an actual stdio pipe specifically to catch it.

### Mocked ACP surface

The mock supports initialization, auth/logout, session lifecycle (`new`, `load`, `resume`, `close`, `list`, `delete`), prompt turns, cancellation, legacy modes, session config options, slash commands, permission requests, model discovery/switching, and mock extension methods under `_mock/*`.

By default, its advertised surface is intentionally Devin-like and app-relevant: visible config is limited to `model`, visible slash commands are `help`, `plan`, `review`, `fix`, and `test`, and mock-only `_mock/*` helpers are callable but not advertised through initialization metadata. `_mock/list_slash_commands` intentionally returns both visible commands and hidden QA commands for direct protocol probing.

Permission requests aren't just a standalone demo path: the edit scenario (triggered by `/fix`, or a prompt containing "edit"/"fix"/"refactor") sends a `session/request_permission` for its simulated diff before applying it, so approval-mode UI can be exercised without needing the literal word "permission"/"approve" in the prompt. A dedicated scenario triggered by those exact words (`permissionScenario`) still exists for direct testing. `/progress-demo` and prompts containing "progress demo" run a deterministic all-in-one QA turn with message streaming, plan updates, successful and failed/permission-gated tool states, usage threshold updates, and final `end_turn`.

The server emits realistic `session/update` notifications for:

- agent/user message chunks and agent thought (reasoning) chunks
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

Model selection is exposed through the ACP-native `configOptions` response (`configId: "model"`, set with `session/set_config_option`) and through direct mock extension methods (`_mock/list_models`, `_mock/set_model`). Slash commands are advertised with `available_commands_update` so autocomplete and command-palette UI can be tested without adding real agent logic. Hidden prompt phrases such as `fail`, `progress demo`, `refuse`, `max tokens`, `permission`, and `web` / `fetch` still exercise QA edge states without appearing in the visible slash-command menu; `_mock/list_slash_commands` exposes hidden commands, including `/progress-demo`, for composer discovery.

### Manual testing with the app

`app/` does not use the mock server for normal chat/session work unless `LEVEL5_USE_ACP_MOCK=1` is set. The convenient manual command for inspecting that behavior is:

```bash
cd app
bun run dev:mock
```

Use `./start.sh` from `acp-mock-server/` when manually testing stdio protocol behavior outside the app.

Mock-mode app runs use `~/.level5-build/acp-mock-state.json` for state unless `ACP_MOCK_STATE_PATH` is set. Override the mock entrypoint with `LEVEL5_ACP_MOCK_START_PATH`.

### Verification

From `acp-mock-server/`:

```bash
bun install
bun run build
bun run typecheck
bun test
```

From the repo root:

```bash
bash -n acp-mock-server/start.sh
bash -n acp-mock-server/start-tcp.sh
```

Use `./start.sh` for ACP stdio smoke tests instead of package-manager script wrappers; command banners before process output would pollute ACP stdout.

## `app/` — the Level5 Build app

Stack: [Bun](https://bun.sh) (runtime + main process), [Electrobun](https://blackboard.sh/electrobun) (desktop app shell using the OS's native webview — WKWebView on macOS, WebView2 on Windows, webkit2gtk on Linux — not a bundled Chromium/CEF; `bundleCEF` is explicitly disabled for all platforms), React 18, Jotai for webview UI state, [`use-stick-to-bottom`](https://github.com/stackblitz-labs/use-stick-to-bottom) for the transcript's auto-scroll/stick-to-bottom behavior, Vite 6 (bundles the webview UI), Tailwind CSS v4, [`liquid-glass-react`](https://github.com/rdev/liquid-glass-react) for the sparse circular top-chrome glass controls, and a manually-configured shadcn/ui foundation. Package management and script execution both use Bun uniformly (no pnpm).

Electrobun is not Electron — it has a different architecture and API surface. Don't assume Electron APIs/patterns apply.

### Process model

- **Main process** (`app/src/bun/index.ts`, runs under Bun): creates the `BrowserWindow`, owns app lifecycle, and implements the bun-side RPC handlers.
- **Webview** (`app/src/mainview/`): a normal React SPA. Vite's project root is `src/mainview`; it builds to `app/dist`.
- **Webview state** (`app/src/mainview/state/`): small Jotai atoms for cross-component UI state such as sidebar collapse and width.

### Build / dev flow

- `bun run start`: `vite build` bundles the webview into `app/dist`, then `electrobun dev` runs the main process against the bundled assets. `electrobun.config.ts`'s `build.copy` maps `dist/index.html` -> `views/mainview/index.html`, `dist/assets` -> `views/mainview/assets`, and fixture/runtime assets -> their app resource locations; the main process loads the webview from the `views://mainview/index.html` custom protocol.
- `bun run dev`: runs `electrobun dev --watch` without rebuilding the Vite webview first. Use it only when bundled assets already exist or the change is limited to Electrobun-side files.
- `bun run dev:hmr`: runs a live Vite dev server (`localhost:5173`) alongside `bun run start`. `app/src/bun/index.ts` probes the dev server on startup (only when the Electrobun update channel is `"dev"`) and points the window at it instead of the bundled `views://` assets when it's reachable, enabling HMR.
- `bun run build`: production build (`vite build && electrobun build`).
- `app/scripts/` also holds release scripts (`sync-version.ts`, `package-macos.ts`, `emit-homebrew-cask.ts`, `apply-macos-icon.ts`) wired into `.github/workflows/release.yml` (see `docs/RELEASE.md`).

### Release automation

Releases are handled by the root `.github/workflows/release.yml` workflow: it installs dependencies, syncs the release version, builds and signs with Electrobun (`bun run build:stable`, codesign/notarize via env vars Electrobun reads directly), packages a DMG, publishes a GitHub Release, and updates the stable Homebrew cask. See `docs/RELEASE.md` for the full flow and required secrets.

### App icon packaging

The source logo lives at `app/assets/icon.png`; the macOS bundle icon lives at `app/assets/App.icns`. A post-build hook (`app/scripts/apply-macos-icon.ts`) copies `App.icns` into the app bundle before codesigning/notarization and updates the bundle plist icon keys. This avoids relying on Electrobun's `.iconset` conversion path, which depends on `iconutil` behavior on the build host.

Both `icon.png` and `App.icns` are regenerated from `app/assets/AppIconSource.png`, not designed independently. To regenerate: `sips -z <N> <N> app/assets/AppIconSource.png --out app/src/mainview/assets/app-icon.png` for the in-app asset, and build a full `.iconset` (16/32/64/128/256/512/1024, `@2x` variants included) from the same source with `sips`, then `iconutil -c icns <iconset-dir> -o app/assets/App.icns` for the bundle icon. Do this on macOS, since `apply-macos-icon.ts` deliberately avoids Electrobun's own `.iconset` conversion path for the reason above, so nothing else in the build regenerates `.icns` for you.

The webview should not import the full application icon directly for small UI chrome. Use optimized web assets under `app/src/mainview/assets/` such as `app-icon.png`, which is sized for in-app display and emitted by Vite with the rest of the webview assets.

### Fonts and webview assets

The webview bundles product fonts from `app/src/mainview/assets/fonts/` and declares them in `app/src/mainview/index.css`. The UI font is Barlow; code and monospace surfaces use Departure Mono. Because these fonts are bundled into the Vite build, the app does not depend on the user's local Font Book at runtime.

### Design tokens

`app/src/mainview/index.css` implements the design language documented in `docs/DESIGN.md` (colors, type scale, spacing/radius/size, elevation, and glass tokens) as CSS custom properties and Tailwind v4 `@theme inline` entries. This CSS file, together with `docs/DESIGN.md`, is the canonical source of truth for the design system — there is no separate native implementation to keep in sync with anymore.

- `--l5-*` custom properties hold the actual color values: light values live in `:root`, and dark values are applied through `@media (prefers-color-scheme: dark)`. The pre-existing shadcn variable names (`--background`, `--primary`, `--muted-foreground`, `--border`, etc.) are kept as aliases onto the `--l5-*` values so existing Tailwind utility classes (`text-muted-foreground`, `border-border`, ...) keep resolving without a rename; new code can use either, but should prefer the `--l5-*`-backed color/utility that matches the concept (e.g. `bg-l5-surface` over inventing a new literal translucency).
- `--text-display/h1/h2/h3/body/caption/mono`, `--radius-window/panel/card/input/button/medium/small/chip`, and `--shadow-e1/e2/e3` mirror the documented type scale, radius scale, and elevation scale respectively, each generating a matching Tailwind utility class (e.g. `text-h2`, `rounded-card`, `shadow-e2`). Tailwind's `--text-*` theme keys carry font size (and line-height via the `--text-<name>--line-height` companion) but not weight, so pair each with a `font-*` weight utility at the call site rather than expecting the size class alone to set weight.
- shadcn/ui is configured by `app/components.json`, with source components checked into `app/src/mainview/components/ui/`. Added shadcn components should be treated as local source, reviewed after generation, and adapted to Level5 tokens instead of using `dark:` overrides or stock fixed surfaces. The current `Select` component uses `@radix-ui/react-select` directly rather than the broad `radix-ui` umbrella package.
- The liquid-glass app frame is split between CSS and a React dependency: `.l5-liquid-pane` / `.l5-frame-top-gradient` / `.l5-sidebar-toggle-shell` provide the floating sidebar pane, translucent top fade, and animated sidebar expand/collapse affordance; `liquid-glass-react` is used only for the sparse circular Dashboard/Review top controls. Do not wrap the tall sidebar pane in `liquid-glass-react`: its internal absolute positioning is tuned for compact controls and has already proven unsuitable for a full-height fixed pane.
- `app/src/mainview/lib/icon-map.ts` centralizes `lucide-react` icon usage behind a single `ICONS` map — app code should reference `ICONS.<concept>` rather than importing `lucide-react` icons ad hoc.

### Main process ⇄ webview RPC

A typed RPC contract lives in `app/src/shared/rpc.ts` (`AppRPC`, built on Electrobun's `RPCSchema`). It's implemented on the main-process side via `BrowserView.defineRPC` (passed into the `BrowserWindow` constructor) in `app/src/bun/index.ts`, and consumed in the webview via `Electroview.defineRPC` in `app/src/mainview/lib/electrobun.ts` (exported as `electroview`). To add a new main-process capability: add the method to `AppRPC.bun.requests`, implement the handler in `src/bun/index.ts`, and call it from the webview via `electroview.rpc.request.<method>()`.

The app's RPC includes the agent runtime surface:

- `selectProjectFolder()`: opens a directory picker. Folder selection is optional.
- `selectAttachmentFile()` / `selectAttachmentFolder()`: open single-selection file/directory pickers for the composer's "Add to prompt" menu, independent of the project-folder picker above.
- `prepareAgentSession({ cwd, approvalMode })`: warms up ACP for a selected project folder using the persisted ACP provider setting (`devin` by default, or `omp`; see "Durable persistence" below) — `devin` starts `devin --permission-mode <mode> acp`, `omp` starts `omp acp`; with `LEVEL5_USE_ACP_MOCK=1`, it starts the bundled/repo-local mock server instead regardless of the provider setting. It initializes ACP, creates or reuses a session for the cwd, and lets ACP `configOptions` / `available_commands_update` populate composer controls before the first prompt.
- `startAgentPrompt({ prompt, cwd, model, approvalMode, attachments })`: accepts a non-empty prompt and starts the ACP prompt flow if no turn is already running. `attachments` are sent as `resource_link` content blocks alongside the text block. For the `devin` provider, `approvalMode` maps to process flags: `ask` and `auto` use `--permission-mode normal`; `full-access` uses `--permission-mode bypass`. The `omp` provider takes no per-launch permission-mode flag — its approval behavior comes from `omp`'s own config (`tools.approvalMode` / CLI overrides), not this app's approval-mode selector; ACP `session/request_permission` still drives the same auto-approve/surface-to-user logic either way.
- `cancelAgentPrompt()`: sends ACP `session/cancel` for the active turn and answers pending permission requests with ACP's cancelled outcome. The composer send button becomes this stop control while a turn is active.
- `respondToAgentPermission({ requestId, optionId })`: answers `session/request_permission` requests that were surfaced to the user (approval mode `ask`, or any request the client could not auto-resolve). Responses use ACP's selected-outcome shape: `{ outcome: { outcome: "selected", optionId } }`.
- `listAgentSessions()`: returns the durable local session cache directly (`AgentRuntimeContext.sortedSessions()`). There is no ACP `session/list` call anywhere in this path -- a backend's own session history must never bleed into the sidebar; this app's SQLite cache is the sidebar's only source of truth. It never spawns or talks to any agent process.
- `listAgentSlashCommands()` / `listAgentSkills()`: return cached composer menu data. Slash commands come from ACP `available_commands_update`; the Skills group is hidden unless a future agent surface advertises real skills separately.
- `loadAgentSession({ sessionId })`: loads or resumes a known session and replays the cached transcript into the webview.
- `deleteAgentSession({ sessionId })`: deletes a session through ACP and removes the app-side session/transcript cache entry.
- `startNewAgentChat()`: clears the active session selection without terminating the connected Devin process.
- `resetAgentChat()`: clears the current chat and terminates the Devin process if one is running.
- `getProjectGitStatus({ cwd })`: returns non-throwing git summary data for the selected project folder so the webview dashboard can show branch and change counts without spawning processes in React. The main process resolves the repository root with `git -C <cwd> rev-parse --show-toplevel`, reads branch/change state with `git status --porcelain=v1 --branch`, and sums tracked line counts with `git diff --numstat`. Untracked files count toward the changed-file total, but their contents are not read for line totals. Repositories before the first commit are valid: the helper detects missing `HEAD` and diffs against Git's empty tree hash instead of treating the folder as non-git.
- `agentUpdate`: Bun-to-webview message stream used for normalized agent status, messages, streamed reasoning ("thought" updates), plan updates, tool calls, context/usage updates, config options, slash commands, permission requests, session summaries, errors, informational notes, and stop reasons.
- `listRecentProjects()`: returns the durable `RecentProjectStore`-backed recent-projects list (see "Durable persistence" below).
- `getAcpProvider()`: returns the persisted ACP provider setting (`"devin"` or `"omp"`).
- `setAcpProvider({ provider })`: persists the ACP provider setting for future sessions. Does not restart or otherwise touch any already-running `ProjectAgentConnection`; the new provider takes effect on that project's next `ensureProcess` call (see "Concurrency and race guards" below), which detects the backend change via the same cwd/permission-mode mismatch check used for approval-mode changes and transparently respawns.
- `listAgentConfigOptions()`: pull-based fallback for composer config (currently just the model selector) alongside the push-based `config` `agentUpdate`, since that push can race webview mount for an already-warm session. Awaits the target project's in-flight `ensureProcess`/`ensureInitialized`/`ensureSession` setup (if any) before reading config, rather than sampling instantly: against a real backend (`devin`/`omp`) the process spawn + `initialize` + `session/new` handshake takes real wall-clock time (observed 0.6-3s+, versus near-0ms for the mock server), so an instant read taken at webview-mount time reliably lost that race and left the model selector permanently empty. Bounded by the ACP transport's own per-request timeout (`ACP_REQUEST_TIMEOUTS_MS.setup`, 15s) rather than hanging indefinitely if the backend is unresponsive; `listAgentSlashCommands()` awaits the same setup for the same reason.

The webview should treat `startAgentPrompt` as an acceptance call, not as the whole agent turn. Agent progress arrives asynchronously through `agentUpdate` messages.

### ACP client flow

The app-side workflow is split between a reusable ACP protocol core in `app/src/bun/acp/`, backend-specific runtime helpers in `app/src/bun/agent/runtime.ts`, and the session adapter in `app/src/bun/index.ts`.

`app/src/bun/acp/` owns the newline-delimited JSON-RPC transport, vendored ACP `v0.11.3` schema validation, typed lifecycle errors, request timeouts, buffered notifications, and the turn idle watchdog. This layer stays provider-agnostic.

`app/src/bun/agent/runtime.ts` owns backend process selection (`selectedAgentBackend`/`buildAgentSpawnOptions`) and each backend's CLI-detection/permission-mode helpers; `app/src/bun/index.ts` contains the session adapter. The user-selected `AcpProviderId` (`"devin"` or `"omp"`, persisted as described in "Durable persistence" below) picks between two real backends; `LEVEL5_USE_ACP_MOCK=1` overrides both and always wins, regardless of the persisted provider. The adapter:

- detects the selected backend's CLI on `PATH` (`devin` or `omp`) and emits a clear install/login error if unavailable;
- for `devin`, spawns `devin --permission-mode normal acp` for `ask` / `auto`, and `devin --permission-mode bypass acp` for `full-access`; for `omp`, spawns `omp acp` with no permission-mode flag (approval is governed by omp's own config, not this app's approval-mode selector);
- skips CLI detection and spawns the mock ACP server when `LEVEL5_USE_ACP_MOCK=1`, using `LEVEL5_ACP_MOCK_START_PATH` as an optional entrypoint override;
- passes `process.env` through so the backend can use its own CLI login state or environment credentials such as `WINDSURF_API_KEY`;
- initializes ACP with honest v1 client capabilities: no client-side filesystem or terminal capability is advertised;
- sends `initialize`, then `session/new` or `session/load`, then optional `session/set_config_option` for model, then `session/prompt`;
- never calls ACP `session/list`: on app open, the webview calls `listAgentSessions`, which returns the durable local session cache directly with no live agent process involved, so the sidebar can show persisted chats without waiting for project selection or first prompt, and without a backend's own (potentially much larger, cross-app) session history bleeding into it. Composer metadata remains lazy: `listAgentSlashCommands` and `listAgentSkills` return cached/empty data until a session is prepared or loaded;
- warms up the selected backend on project selection through `prepareAgentSession` so model config and slash commands are available before first send;
- when the backend sends `session/request_permission`, `auto` chooses an allow-like option if one is available and emits an informational note; otherwise the request is surfaced to the webview;
- preserves the selected approval mode across process restarts caused by cwd, permission-mode, or ACP provider changes;
- watches active prompt turns for inbound ACP activity. If a turn goes silent past the configured idle budget, or if the user hits stop, the adapter sends `session/cancel`, answers pending permission requests with ACP's cancelled outcome, and rejects local pending requests;
- reuses the current session for subsequent prompts in the same cwd;
- closes and recreates the session if the selected folder changes;
- resolves folderless prompts to the user's home directory for ACP `cwd`, while the UI continues to show no selected project;
- keeps an app-side in-memory map of session summaries so the sidebar can show a newly created session immediately after `session/new`;
- keeps an app-side in-memory transcript cache for each known session, including message chunks, thought (reasoning) chunks, plans, tool calls, and the latest usage/context-window update;
- writes the user's own prompt into that transcript cache itself, synchronously at send time (`startPrompt`, before `session/prompt` is even dispatched), rather than waiting for the ACP process to echo it back as a `user_message_chunk` notification — real Devin/omp has been observed to never send that echo, which previously meant no user-authored message ever made it into `~/.level5build/level5.sqlite` (see "Durable persistence" below);
- normalizes ACP notifications into webview-friendly `AgentUpdate` messages.

The default prompt idle timeout is 120 seconds and can be overridden for local testing with `LEVEL5_ACP_TURN_IDLE_TIMEOUT_MS`.

Full transcript caches are still in memory and are reset when the main process exits; persisted sessions loaded after relaunch replay through ACP.

### Durable persistence

`app/src/bun/persistence/database.ts` owns a single `bun:sqlite` connection at `~/.level5build/level5.sqlite` and an ordered list of migrations. `RecentProjectStore` (`app/src/bun/persistence/recentProjectStore.ts`) persists the recent-projects list there: `upsertSelectedFolder` records normalized path, display name, and timestamps on project selection, and `listRecentProjects` (exposed to the webview via the `listRecentProjects` RPC) returns them ordered by last-opened, pruned to the 10 most recent.

`app/src/bun/persistence/settingsStore.ts` persists app-wide settings as a generic `settings(key, value)` key-value table sharing the same connection, rather than a dedicated column/table per setting: `getSetting`/`setSetting` are the only two operations. The ACP provider choice (`AcpProviderId`) is stored under the `"acpProvider"` key (`SETTINGS_KEY_ACP_PROVIDER` in `app/src/bun/agent/runtime.ts`), loaded once into `AgentRuntimeContext.acpProvider` at process startup, read by `ProjectAgentConnection.ensureProcess`, and updated via the `setAcpProvider` RPC (see "Main process ⇄ webview RPC" above).

Sessions themselves warm up eagerly but are not written to SQLite until the first message is actually sent: `prepareSession`'s warm-up path (project selection, composer priming) passes `persist: false`, while `startPrompt`'s actual send always persists, even when reusing an already-warmed session. This keeps an unsent "New chat" from appearing in the sidebar or on disk. When the renderer already holds a prepared session id, `startPrompt` first `session/load`s or `session/resume`s that id for backend context and then immediately calls `persistCurrentSession` before `session/prompt` can stream transcript rows; otherwise those rows would violate the transcript table's foreign key to `sessions`. Because a single `ProjectAgentConnection` can switch between already-persisted and not-yet-persisted sessions, `primeSession` must reset the per-current-session `sessionPersisted` flag whenever it switches to a different session.

This invariant isn't just enforced at write time: some backends (the mock server's post-`session/new` timer, and plausibly real Devin too) push a `session_info_update` notification unprompted right after session creation, before any message was ever sent. `shouldPersistSessionInfoUpdate` (`app/src/bun/agent/runtime.ts`) guards `handleNotification`'s `session_info_update` branch against exactly that: it only persists when the notification's session id matches the connection's current session AND that session has already flipped `sessionPersisted` via an actual send, so an unprompted warm-up notification can never sneak an unsent "New chat" into SQLite through the push path either.

The user's own prompt message is written into the transcript by the app itself, not by relaying an ACP echo: `startPrompt` (`app/src/bun/index.ts`) synthesizes and persists a `kind: "message", role: "user"` transcript entry the moment a real session id is resolved, before `session/prompt` is even dispatched. Earlier revisions relied on the ACP process echoing the prompt back as a `user_message_chunk` notification to trigger persistence; real Devin/omp has been observed to never send that echo at all (only the mock server always does), which meant every persisted session was silently missing its own opening question — visible for the live session via the renderer's purely local optimistic bubble, but gone the moment the app relaunched, since nothing had ever written it to SQLite. The live `user_message_chunk` notification (when a backend does send one) is now unconditionally dropped in `handleNotification`, since treating it as a second write would risk duplicating or racing the authoritative one. `upsertTranscriptUpdate`'s message/thought merge logic only falls back to "append onto whatever's last" when the incoming update carries no `messageId` at all (some backends omit it on streamed chunks) — a distinct, real `messageId` (such as this synthesized message's freshly generated one) is always treated as a new entry, never silently concatenated onto an unrelated prior message of the same role.

### Concurrency and race guards

Like the ACP surface above, per-project concurrent agent processes and their composer-priming race guard are load-bearing correctness properties, not incidental: `ProjectAgentConnection` (in `app/src/bun/index.ts`) serializes `ensureProcess`/`ensureInitialized`/session-creation across `startPrompt`, `prepareSession`, and `bestEffortDeleteSession` for the same project through a `connectionSetupChain: Promise<void>` (`withConnectionSetupLock`), so an unrelated `session/new`/`session/load` racing a real prompt against the same underlying process can't corrupt session state. Git subprocess calls (`app/src/bun/git/status.ts`) have a 3-second timeout on each spawned `git` command so a hung repository (e.g. an unresponsive credential helper) can't hang the dashboard indefinitely.

### Window chrome

The window is frameless: `titleBarStyle: "hiddenInset"` (native traffic lights, no visible title bar strip, `FullSizeContentView` so the webview covers the whole window). The native traffic lights are positioned with `TRAFFIC_LIGHT_OFFSET` in `app/src/bun/index.ts`, passed as `trafficLightOffset` during `BrowserWindow` creation and re-applied with `setWindowButtonPosition`. This is native window state, not CSS: frontend HMR can refresh the webview without re-running the Bun-side offset call, so a development window may temporarily snap back to the platform default until the Electrobun app is restarted or the main process reapplies the position.

Because the webview covers the title bar area, window dragging has to be opted into explicitly via the `electrobun-webkit-app-region-drag` CSS class (Electrobun's equivalent of Electron's `-webkit-app-region: drag`); any future interactive controls placed over a draggable region need `electrobun-webkit-app-region-no-drag` to stay clickable. The current draggable strip starts to the right of the native macOS traffic lights so close/minimize/zoom remain clickable.

**Known upstream limitation:** Electrobun's window drag is implemented as a custom mouse-tracking move (not the OS's native window-drag/move loop), so dragging to the screen edges or top does not trigger native window tiling/snap the way a normal window would (tracked upstream: [blackboardsh/electrobun#395](https://github.com/blackboardsh/electrobun/issues/395), [#406](https://github.com/blackboardsh/electrobun/pull/406), [#417](https://github.com/blackboardsh/electrobun/pull/417)). As a stand-in, double-clicking the window background calls the `toggleMaximizeWindow` RPC method to fill/restore the screen, mirroring the native "double-click title bar to zoom" convention. A native drag-region overlay (the approach some other Electrobun apps use to get real OS drag/tiling) was deliberately not adopted here: it would sit as an opaque `NSView` above the entire WKWebView within its rectangle, silently swallowing clicks on the interactive controls (sidebar toggle, dashboard/review triggers) that live inside today's draggable strip.

Electrobun's `ApplicationMenu` has no public vibrancy API, so real `NSVisualEffectView`-backed sidebar material (matching Apple's own Finder/Photos/Maps sidebars, not just a CSS `backdrop-filter` blurring an opaque background) needs a small native bridge: `app/native/macos/window-effects.mm` (compiled by `scripts/build-macos-effects.sh` into `src/bun/libMacWindowEffects.dylib`, gitignored as a build artifact) is loaded via `bun:ffi` in `src/bun/macWindowEffects.ts` and applies `NSVisualEffectMaterialSidebar` vibrancy plus a window shadow after `BrowserWindow` creation. The window itself must be `transparent: true` (macOS only) for this to be visible; the outer app container is `bg-transparent` with an explicit opaque backdrop `div` behind the full workspace, while the floating sidebar pane and top controls use translucent CSS/glass layers over that native material. Every `dev`/`build*` script depends on a `build:macos-effects` pre-step; loading is best-effort (falls back to opaque/transparent-only if the dylib is missing or `dlopen` fails) and gated to `process.platform === "darwin"`.

### Text editing keyboard shortcuts

Electrobun's webview does not wire up standard text-editing keyboard shortcuts (`cmd+a`, `cmd+c`, `cmd+v`, `cmd+x`, `cmd+z`, etc.) on its own — on macOS these are dispatched through the app's native menu bar, not raw webview key events. `app/src/bun/index.ts` registers a native Edit menu via `ApplicationMenu.setApplicationMenu([...])` with the standard `undo`/`redo`/`cut`/`copy`/`paste`/`pasteAndMatchStyle`/`delete`/`selectAll` roles at startup so these shortcuts work anywhere text is focused in the webview (the composer, search inputs, etc.). Any new text-editing shortcut needs a corresponding role or explicit `accelerator` added to that menu.

**Gotcha:** unlike those Edit-menu roles, `role: "quit"` does **not** get a default key equivalent from Electrobun on its own — Cmd+Q silently did nothing until an explicit `accelerator: "q"` was added to that menu item. Electrobun's `accelerator` format is also not Electron's `"CmdOrCtrl+Q"` string; it's just the bare key, with the Cmd/Ctrl modifier applied automatically per platform.
