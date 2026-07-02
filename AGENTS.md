# Agent notes

This repo hosts `app/`, an Electrobun (Bun + native OS webview) desktop app using React, Tailwind CSS v4, and a manually-configured shadcn/ui foundation. See `docs/ARCHITECTURE.md` for the technical architecture and `docs/DESIGN.md` for styling/component conventions.

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

## Gotchas

- Electrobun is not Electron — don't assume Electron APIs/patterns apply.
- Electrobun's window drag doesn't support native OS window tiling/snap (see `docs/ARCHITECTURE.md`); don't be surprised this doesn't "just work" like a normal window.
- Tailwind is v4 (CSS-based config in `app/src/mainview/index.css`) — there is no `tailwind.config.js`.
