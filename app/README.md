# Level5 Build

Level5 Build is an Electrobun desktop app: Bun + a native OS webview (no bundled Chromium/CEF), React 18, Vite 6 for the webview bundle, Tailwind CSS v4, and a manually-configured shadcn/ui foundation.

Currently the app is an early desktop AI coding agent shell: a single frameless window with a code-native white gradient backdrop, light translucent chrome, a composer-first agent workspace, and the runtime, RPC, styling, and component foundation in place for the product workspace.

## Native 1.0 transition

This directory currently contains the Electrobun proof of concept. The accepted 1.0 direction is a native macOS client; see `../docs/adr/0001-native-macos-client.md`.

During native scaffold work, this Electrobun app will move to `../legacy/electrobun-app/` for reference, and the new native macOS app will take over `app/`. Until that scaffold lands, the commands below remain the current way to run and verify the POC.

See also:

- `../docs/PRODUCT.md` for product direction
- `../docs/ARCHITECTURE.md` for runtime architecture
- `../docs/DESIGN.md` for visual and interaction rules
- `../docs/adr/0001-native-macos-client.md` for the native macOS 1.0 decision

## Getting Started

```bash
# Install dependencies
bun install

# Build the webview once, then launch Electrobun against bundled assets
bun run start

# Development with HMR (recommended)
bun run dev:hmr

# Development with HMR against the local ACP mock backend
bun run dev:mock

# Watch Electrobun-side files without rebuilding the Vite webview first
bun run dev

# Build for production (bundles the webview, then builds the app)
bun run build

# Build a stable macOS release artifact
bun run build:stable

# Run the current local check suite
bun run lint
bun run test
bun run build:web

# Full app bundle check without launching the GUI
bun run build
```

## ACP Agent Runtime

The app's production agent workflow uses Devin ACP. Opening the app shows the composer and connects to the selected ACP backend once to initialize it and call `session/list`, so the sidebar can show persisted chats immediately. This launch-time connection does not create a new chat session. Selecting a project warms up the app-side ACP client for that cwd, spawns or reuses `devin --permission-mode <mode> acp`, creates an ACP session, and lets the composer receive model choices and slash commands before the first prompt. If no project is selected, the first valid Send lazily starts or reuses Devin using the user's home directory as cwd without presenting it as the selected project.

The app-side ACP code is split into a reusable protocol core under `src/bun/acp/`, runtime helpers under `src/bun/agent/`, and the session adapter in `src/bun/index.ts`. The core handles NDJSON JSON-RPC transport, vendored ACP `v0.11.3` schema validation, request timeouts, pending-request cleanup, buffered notifications, extension request handling, and the idle-turn watchdog.

Devin must be installed and authenticated outside the app. Make sure `devin` is on `PATH` and run `devin auth login` before starting an agent chat. The app passes through `process.env`, so environment-based credentials such as `WINDSURF_API_KEY` remain available to Devin.

For local manual testing without Devin, run the app against the bundled mock ACP backend:

```bash
bun run dev:mock
```

This sets `LEVEL5_USE_ACP_MOCK=1`, skips Devin CLI detection, and uses the bundled or repo-local `acp-mock-server/src/index.ts` over stdio. In mock mode, startup session listing spawns the mock backend immediately so `session/list` can populate the sidebar from persisted mock state; preparing a project or sending the first prompt then creates or loads the actual chat session. Mock app state defaults to `~/.level5-build/acp-mock-state.json`; override the state path with `ACP_MOCK_STATE_PATH` or the mock entrypoint with `LEVEL5_ACP_MOCK_INDEX_PATH` when testing a custom mock checkout.

Approval modes map to Devin permission modes conservatively: `ask` and `auto` spawn Devin with `--permission-mode normal`; `full-access` spawns Devin with `--permission-mode bypass`. In `auto`, ACP permission requests are answered with the first allow-like option when available. In v1 the app does not advertise ACP filesystem or terminal client capabilities.

While a prompt turn is running, the composer send button becomes a stop button that sends ACP `session/cancel`. If a prompt turn goes silent for too long, the adapter also sends `session/cancel`, answers pending permission requests with ACP's cancelled outcome, rejects local pending requests, and resets the subprocess so stale output from the timed-out turn cannot leak into a later prompt. The default idle timeout is 120 seconds and can be overridden with `LEVEL5_ACP_TURN_IDLE_TIMEOUT_MS` for local testing.

The sidebar's `All chats` list is backed by ACP `session/list` on startup plus app-side in-memory session summaries created during the current run. A row appears as soon as `session/new` succeeds for the first prompt. The app also keeps an in-memory transcript cache for each known session so selecting a previous chat restores message, plan, tool, and context-usage cards. The app-side full transcript cache is reset when the Electrobun main process exits; restart the main process after changing Bun-side RPC handlers or cache behavior.

The composer's `+` ("Add to prompt") menu offers file/folder attachments sent as `resource_link` content blocks. Slash commands populate from ACP `available_commands_update`; the Skills group is hidden unless a future agent surface advertises real skills.

The `../acp-mock-server` package remains as a protocol simulator and test fixture. For protocol-level testing, spawn the mock directly with:

```bash
cd ../acp-mock-server
./start.sh
```

`./start.sh` keeps stdout JSON-RPC-only for ACP clients; diagnostic logs go to stderr.

## How HMR Works

When you run `bun run dev:hmr`:

1. **Vite dev server** starts on `http://localhost:5173` with HMR enabled
2. **Electrobun** starts and detects the running Vite server
3. The app loads from the Vite dev server instead of bundled assets
4. Changes to React components update instantly without a full page reload

When you run `bun run dev` (without HMR):

1. Electrobun starts in watch mode
2. The app loads from `views://mainview/index.html`
3. Bundled webview assets must already exist; use `bun run start` to rebuild them before launching
4. Use this mostly for Bun/main-process changes, not React UI iteration

## Project Structure

```
├── src/
│   ├── bun/
│   │   ├── acp/              # ACP transport, schema validation, timeouts, and watchdog utilities
│   │   └── index.ts          # Main process: creates the BrowserWindow, defines the bun-side RPC handlers
│   ├── mainview/              # Webview UI (React), Vite root
│   │   ├── App.tsx            # React app component
│   │   ├── main.tsx           # React entry point
│   │   ├── index.html         # HTML template
│   │   ├── index.css          # Tailwind v4 + shadcn theme tokens
│   │   ├── assets/            # Images etc. imported directly by components
│   │   └── lib/
│   │       ├── utils.ts       # shadcn's cn() helper (clsx + tailwind-merge)
│   │       └── electrobun.ts  # Webview-side RPC client (Electroview)
│   └── shared/
│       └── rpc.ts             # Typed RPC contract shared between bun and webview
├── components.json            # shadcn/ui config (run `bunx shadcn@latest add <component>` here)
├── assets/                    # App icons and generated macOS icon files
├── scripts/                   # Release/version/package helper scripts
├── electrobun.config.ts       # Electrobun app metadata + build/copy config
├── vite.config.ts             # Vite config (React + Tailwind v4 plugins, @ and @shared aliases)
├── tsconfig.json              # Path aliases matching vite.config.ts
└── package.json
```

## Customizing

- **React components**: edit/add files in `src/mainview/` (use `bunx shadcn@latest add <component>` for shadcn components — they land in `src/mainview/components/ui/`)
- **Tailwind theme**: edit `src/mainview/index.css` (Tailwind v4 is CSS-based config — there is no `tailwind.config.js`)
- **Vite settings**: edit `vite.config.ts`
- **Window settings** (size, title bar style, drag regions): edit `src/bun/index.ts` and the `electrobun-webkit-app-region-drag` / `-no-drag` classes in the webview
- **App metadata**: edit `electrobun.config.ts`
- **Release version**: push tags like `v0.0.0`; CI syncs `package.json`, `electrobun.config.ts`, and `src/shared/version.ts`
- **Main process ⇄ webview calls**: add methods to the `AppRPC` type in `src/shared/rpc.ts`, implement the handler in `src/bun/index.ts`, call it from the webview via `electroview.rpc.request.<method>()`
- **ACP protocol core**: edit `src/bun/acp/` for JSON-RPC transport, ACP schema validation, timeout, cancellation, and watchdog behavior. Keep this layer UI-agnostic.
- **Devin ACP runtime**: edit `src/bun/agent/` for Devin command/permission-mode helpers, `src/bun/index.ts` for session adapter behavior, and `src/mainview/App.tsx` for composer/transcript rendering. App open intentionally connects once for `initialize` + `session/list`, but should not create a new chat session until project warm-up, session load, or first prompt.

## CI and Releases

GitHub Actions runs app checks on pushes and pull requests to `main`:

- `bun install --frozen-lockfile`
- `bun run lint`
- `bun run test`
- `bun run build:web`

Pushing a tag like `v0.0.0` runs the release workflow. It syncs the version from the tag into `package.json`, `electrobun.config.ts`, and `src/shared/version.ts`, builds a stable macOS artifact, creates a GitHub Release, updates `dante-teo/homebrew-tap`, and commits the synced version back to `main`.

The Homebrew release is currently macOS ARM64-only. The generated cask includes `depends_on arch: :arm64`; add Intel/Windows packaging later as separate release work.

Required repository secrets for signed Homebrew releases:

- `APPLE_CERTIFICATE_P12`
- `APPLE_CERTIFICATE_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `ELECTROBUN_DEVELOPER_ID`
- `ELECTROBUN_TEAMID`
- `ELECTROBUN_APPLEID`
- `ELECTROBUN_APPLEIDPASS`
- `HOMEBREW_TAP_TOKEN`

`MACOS_KEYCHAIN_PASSWORD` is just a random password for the temporary GitHub Actions keychain. `HOMEBREW_TAP_TOKEN` only needs write access to `dante-teo/homebrew-tap`.

## Known limitation: no native window-tiling on drag

Electrobun's window drag doesn't hook into the OS's native move loop, so dragging the window to the screen edges/top won't auto-snap/tile like a normal native window (tracked upstream: [blackboardsh/electrobun#395](https://github.com/blackboardsh/electrobun/issues/395)). As a stand-in, double-clicking the window background toggles maximize/fill-screen, via the `toggleMaximizeWindow` RPC method.
