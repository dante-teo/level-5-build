# Architecture

## Repo layout

This repo currently hosts:

- `app/`, a self-contained Electrobun desktop app project with its own `package.json`, lockfile, and dependencies.
- `acp-mock-server/`, a standalone Bun/TypeScript Agent Client Protocol mock server for local client and integration testing.
- `scripts/`, root-level helper scripts for workflows that span multiple packages.
- `docs/`, shared architecture/product/design documentation.

Root-level packages are intentionally independent. The app can be built and checked without the mock server, and the mock server can be spawned by any ACP-compatible client over stdio.

## `acp-mock-server/` — ACP test agent

`acp-mock-server/` is a dependency-light Bun/TypeScript implementation of an ACP v1 agent over newline-delimited JSON-RPC stdio. It is designed for testing client UI and protocol handling without a real model or real code edits.

### Transport and process model

- The protocol entrypoint is `acp-mock-server/start.sh`, which execs `bun src/index.ts`.
- The server reads UTF-8 JSON-RPC messages from stdin and writes only JSON-RPC messages to stdout.
- Logs go to stderr. Do not route diagnostic output to stdout; ACP clients expect stdout to be protocol-clean.
- Session state persists to `.mock-acp-state.json` by default, ignored by git. Override with `ACP_MOCK_STATE_PATH`.

### Mocked ACP surface

The mock supports initialization, auth/logout, session lifecycle (`new`, `load`, `resume`, `close`, `list`, `delete`), prompt turns, cancellation, legacy modes, session config options, slash commands, permission requests, model discovery/switching, and mock extension methods under `_mock/*`.

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

### Model and command testing

Model selection is exposed through the ACP-native `configOptions` response (`configId: "model"`, set with `session/set_config_option`) and through direct mock extension methods (`_mock/list_models`, `_mock/set_model`). Slash commands are advertised with `available_commands_update` so autocomplete and command-palette UI can be tested without adding real agent logic.

### Manual testing with the app

From the repo root:

```bash
./scripts/start-app-with-acp-mock.sh
```

This starts the ACP mock server and `app`'s `bun run dev:hmr` workflow together. The script keeps both process trees tied to the terminal and stops them on `Ctrl-C`.

The app also has a built-in mock ACP client path for the current composer workflow. The main process lazily spawns `acp-mock-server/start.sh` only after the user sends the first prompt; simply opening the app must not start ACP, initialize a session, or list sessions. This keeps the empty workspace cheap and avoids protocol side effects before user intent is clear.

### Verification

From `acp-mock-server/`:

```bash
bun test
bunx tsc --noEmit -p tsconfig.json
```

From the repo root:

```bash
bash -n scripts/start-app-with-acp-mock.sh
bash -n acp-mock-server/start.sh
```

Use `./start.sh` for ACP stdio smoke tests instead of `bun run`; some Bun script invocations echo command banners before process output, which would pollute ACP stdout.

## `app/` — Electrobun desktop app

Stack: [Bun](https://bun.sh) (runtime + main process), [Electrobun](https://blackboard.sh/electrobun) (desktop app shell using the OS's native webview — WKWebView on macOS, WebView2 on Windows, webkit2gtk on Linux — not a bundled Chromium/CEF; `bundleCEF` is explicitly disabled for all platforms), React 18, Jotai for webview UI state, Vite 6 (bundles the webview UI), Tailwind CSS v4, and a manually-configured shadcn/ui foundation.

Electrobun is not Electron — it has a different architecture and API surface. Don't assume Electron APIs/patterns apply.

### Process model

- **Main process** (`app/src/bun/index.ts`, runs under Bun): creates the `BrowserWindow`, owns app lifecycle, and implements the bun-side RPC handlers.
- **Webview** (`app/src/mainview/`): a normal React SPA. Vite's project root is `src/mainview`; it builds to `app/dist`.
- **Webview state** (`app/src/mainview/state/`): small Jotai atoms for cross-component UI state such as sidebar collapse and width.

### Build / dev flow

- `bun run start`: `vite build` bundles the webview into `app/dist`, then `electrobun dev` runs the main process against the bundled assets. `electrobun.config.ts`'s `build.copy` maps `dist/index.html` -> `views/mainview/index.html` and `dist/assets` -> `views/mainview/assets`; the main process loads the webview from the `views://mainview/index.html` custom protocol.
- `bun run dev`: runs `electrobun dev --watch` without rebuilding the Vite webview first. Use it only when bundled assets already exist or the change is limited to Electrobun-side files.
- `bun run dev:hmr`: runs a live Vite dev server (`localhost:5173`) alongside `bun run start`. `app/src/bun/index.ts` probes the dev server on startup (only when the Electrobun update channel is `"dev"`) and points the window at it instead of the bundled `views://` assets when it's reachable, enabling HMR.
- `bun run build`: production build (`vite build && electrobun build`).
- `bun run build:stable`: stable macOS release build (`vite build && electrobun build --env=stable`). Electrobun emits release artifacts under `app/artifacts/`.
- `bun run release:package:mac -- v0.0.0`: copies Electrobun's stable DMG to a versioned GitHub Release artifact name.
- `bun run release:cask`: writes `Casks/level5-build.rb` in the Homebrew tap checkout using the release artifact name and SHA-256 supplied through environment variables.

### Release automation

The release workflow is tag-driven. Pushing a tag like `v0.0.0` causes CI to:

1. Sync the tag version into `app/package.json`, `app/electrobun.config.ts`, and `app/src/shared/version.ts`.
2. Run typecheck, tests, and the stable Electrobun build.
3. Create a GitHub Release with the versioned macOS ARM64 DMG.
4. Update `dante-teo/homebrew-tap` with an ARM64-only Homebrew Cask.
5. Commit the synced version files back to `main`.

`HOMEBREW_TAP_TOKEN` is used only for the tap repository. The main app repository checkout and version-bump push use `GITHUB_TOKEN`.

### App icon packaging

The source logo lives at `app/assets/icon.png`; the macOS bundle icon lives at `app/assets/App.icns`. A post-build hook (`app/scripts/apply-macos-icon.ts`) copies `App.icns` into the app bundle before codesigning/notarization and updates the bundle plist icon keys. This avoids relying on Electrobun's `.iconset` conversion path, which depends on `iconutil` behavior on the build host.

The webview should not import the full application icon directly for small UI chrome. Use optimized web assets under `app/src/mainview/assets/` such as `app-icon.png`, which is sized for in-app display and emitted by Vite with the rest of the webview assets.

### Fonts and webview assets

The webview bundles product fonts from `app/src/mainview/assets/fonts/` and declares them in `app/src/mainview/index.css`. The UI font is Barlow; code and monospace surfaces use Departure Mono. Because these fonts are bundled into the Vite build, the app does not depend on the user's local Font Book at runtime.

### Main process ⇄ webview RPC

A typed RPC contract lives in `app/src/shared/rpc.ts` (`AppRPC`, built on Electrobun's `RPCSchema`). It's implemented on the main-process side via `BrowserView.defineRPC` (passed into the `BrowserWindow` constructor) in `app/src/bun/index.ts`, and consumed in the webview via `Electroview.defineRPC` in `app/src/mainview/lib/electrobun.ts` (exported as `electroview`). To add a new main-process capability: add the method to `AppRPC.bun.requests`, implement it in `src/bun/index.ts`'s handler object, and call it from the webview via `electroview.rpc.request.<method>()`.

Current app RPC includes the mock-agent development surface:

- `selectProjectFolder()`: opens a directory picker. Folder selection is optional.
- `startMockPrompt({ prompt, cwd, model, approvalMode })`: accepts a non-empty prompt and starts the mock ACP flow if no turn is already running.
- `respondToMockPermission({ requestId, optionId })`: answers mock `session/request_permission` requests.
- `resetMockChat()`: clears the current mock chat and terminates the mock server process if one is running.
- `mockAgentUpdate`: Bun-to-webview message stream used for normalized mock status, messages, plan updates, tool calls, permission requests, errors, and stop reasons.

The webview should treat `startMockPrompt` as an acceptance call, not as the whole agent turn. Agent progress arrives asynchronously through `mockAgentUpdate` messages.

### Mock ACP client flow

`app/src/bun/index.ts` contains a small stdio JSON-RPC client for local mock-agent development. It:

- resolves `acp-mock-server/start.sh` lazily when the first prompt is sent, by searching upward from the running process cwd and bundled main file location;
- spawns the mock server with protocol stdout/stderr kept separate;
- sends `initialize`, then `session/new`, then mock config updates for model and mode, then `session/prompt`;
- reuses the current mock session for subsequent prompts in the same cwd;
- closes and recreates the mock session if the selected folder changes;
- resolves folderless prompts to the user's home directory for ACP `cwd`, while the UI continues to show no selected project;
- normalizes ACP notifications into webview-friendly `MockAgentUpdate` messages.

Keep this mock client local-development oriented. Real provider/client architecture should be introduced separately rather than growing production assumptions into this mock path.

### Window chrome

The window is frameless: `titleBarStyle: "hiddenInset"` (native traffic lights, no visible title bar strip, `FullSizeContentView` so the webview covers the whole window). Because the webview covers the title bar area, window dragging has to be opted into explicitly via the `electrobun-webkit-app-region-drag` CSS class (Electrobun's equivalent of Electron's `-webkit-app-region: drag`); any future interactive controls placed over a draggable region need `electrobun-webkit-app-region-no-drag` to stay clickable.

**Known upstream limitation:** Electrobun's window drag is implemented as a custom mouse-tracking move (not the OS's native window-drag/move loop), so dragging to the screen edges or top does not trigger native window tiling/snap the way a normal window would (tracked upstream: [blackboardsh/electrobun#395](https://github.com/blackboardsh/electrobun/issues/395), [#406](https://github.com/blackboardsh/electrobun/pull/406), [#417](https://github.com/blackboardsh/electrobun/pull/417)). As a stand-in, double-clicking the window background calls the `toggleMaximizeWindow` RPC method to fill/restore the screen, mirroring the native "double-click title bar to zoom" convention.
