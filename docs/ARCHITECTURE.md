# Architecture

## Repo layout

This repo currently hosts one app, `app/`, a self-contained project (own `package.json`/`node_modules`/lockfile). The root only holds shared docs and the license — the layout leaves room for additional apps/packages to sit alongside `app/` later.

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

### Window chrome

The window is frameless: `titleBarStyle: "hiddenInset"` (native traffic lights, no visible title bar strip, `FullSizeContentView` so the webview covers the whole window). Because the webview covers the title bar area, window dragging has to be opted into explicitly via the `electrobun-webkit-app-region-drag` CSS class (Electrobun's equivalent of Electron's `-webkit-app-region: drag`); any future interactive controls placed over a draggable region need `electrobun-webkit-app-region-no-drag` to stay clickable.

**Known upstream limitation:** Electrobun's window drag is implemented as a custom mouse-tracking move (not the OS's native window-drag/move loop), so dragging to the screen edges or top does not trigger native window tiling/snap the way a normal window would (tracked upstream: [blackboardsh/electrobun#395](https://github.com/blackboardsh/electrobun/issues/395), [#406](https://github.com/blackboardsh/electrobun/pull/406), [#417](https://github.com/blackboardsh/electrobun/pull/417)). As a stand-in, double-clicking the window background calls the `toggleMaximizeWindow` RPC method to fill/restore the screen, mirroring the native "double-click title bar to zoom" convention.
