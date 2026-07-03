# Agent notes

This repo currently hosts `app/`, an Electrobun (Bun + native OS webview) desktop app using React, Tailwind CSS v4, and a manually-configured shadcn/ui foundation. The accepted native macOS 1.0 direction is documented in `docs/adr/0001-native-macos-client.md`: during scaffold work, the Electrobun POC moves to `legacy/electrobun-app/`, the native app takes over `app/`, and `acp-mock-server/` remains active shared test infrastructure. See `docs/ARCHITECTURE.md` for the technical architecture and `docs/DESIGN.md` for styling/component conventions.

## Setup & running

Requires Bun (`curl -fsSL https://bun.sh/install | bash` if not installed).

```bash
cd app
bun install
bun run start      # build the webview once, then launch the app
bun run dev:hmr     # live-reload dev loop (Vite HMR + Electrobun)
```

## Verification

From `app/`, these should both succeed after webview/main-process changes:

```bash
bunx vite build
bunx tsc --noEmit -p tsconfig.json
```

`tsc` will report one pre-existing, unrelated error about a missing `three` type declaration inside `electrobun`'s own bundled `dist` — that's an upstream packaging issue, not something to fix here.

Avoid actually launching the GUI (`bun run start` / `electrobun dev`) unless asked — it opens a real window, and `vite build` + `tsc --noEmit` catch build/type errors without doing that.

If you need to verify a layout/scroll/visual behavior without launching the GUI: build the webview (`vite build`) and drive the *real* compiled CSS plus real hooks/components in a plain Playwright browser tab (e.g. a tiny standalone bundle via `bun build`, or a static HTML page reusing `app/dist/assets/*.css`), served over a throwaway local HTTP server. This is not the Electrobun app — it's just the web content in an ordinary browser — so it doesn't conflict with the "avoid launching the GUI" guidance, and it can actually reproduce/measure layout bugs (scroll positions, overlap, element geometry) that `tsc`/`vite build` can't catch. Clean up the scratch files, server process, and any `.playwright-mcp/` output when done.

## Gotchas

- Electrobun is not Electron — don't assume Electron APIs/patterns apply.
- Electrobun's window drag doesn't support native OS window tiling/snap (see `docs/ARCHITECTURE.md`); don't be surprised this doesn't "just work" like a normal window.
- Tailwind is v4 (CSS-based config in `app/src/mainview/index.css`) — there is no `tailwind.config.js`.
- Electrobun's webview doesn't wire up standard text-editing shortcuts (cmd+a/c/v/x/z) on its own; they only work because `app/src/bun/index.ts` registers a native `ApplicationMenu` Edit menu with the corresponding roles (see `docs/ARCHITECTURE.md`). Any new text-editing shortcut needs a role/accelerator added there too.
- `app/src/bun/index.ts` (the Electrobun main process) is bundled by Electrobun's own `Bun.build()` call, not Vite — and that bundler does not resolve the `@shared`/`@` path aliases from `tsconfig.json` the way `vite build`/`tsc --noEmit` do. Any real (value-level) import in `src/bun/index.ts` from `@shared/*` must instead use a relative path (e.g. `../shared/rpc`), or `bun run start`/`electrobun build` will fail with `Could not resolve: "@shared/..."` even though `vite build` and `tsc --noEmit` pass cleanly. `import type { ... }` from `@shared/*` is fine either way since type-only imports are erased before bundling and never actually get resolved at runtime.
- Floating top-bar capsules in `App.tsx` (sidebar/session toggle, dashboard trigger) are positioned as independent `position: fixed` elements, not children of one real "top bar" container. When wrapping one of these capsules in an invisible row/box to control alignment (e.g. to give two capsules of different natural heights a shared vertical center via a fixed-height `flex items-center` wrapper), remember that any part of that wrapper's box taller than the visible pill is still hit-testable: without `pointer-events-none` on the wrapper (and `pointer-events-auto` on the actual pill), the invisible padding will silently swallow clicks/double-clicks meant for whatever is behind it. The file already uses this `pointer-events-none`/`pointer-events-auto` split for other decorative/overlay elements — reuse that pattern for any new invisible alignment wrappers instead of leaving the whole box hit-testable.
