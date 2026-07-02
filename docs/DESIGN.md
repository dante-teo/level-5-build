# Design System

## Current state

The app currently renders a single full-bleed background image (`app/src/mainview/assets/background.png`, `background-size: cover`) with no other UI — a blank canvas for future screens.

## shadcn/ui foundation

A shadcn/ui foundation is set up for future component work, configured manually (not via `shadcn init`'s framework auto-detection, since Electrobun's Bun+Vite setup isn't one of its recognized presets):

- Config: `app/components.json` — style `new-york`, base color `neutral`, CSS variables enabled, icon library `lucide`.
- Add components from within `app/`: `bunx shadcn@latest add <component>` — they're generated into `src/mainview/components/ui/` per the aliases below. Double check generated imports resolve correctly against this project's aliases (auto-detection may guess wrong given the non-standard bundler setup).
- Utility: `cn()` in `app/src/mainview/lib/utils.ts` (clsx + tailwind-merge) for merging conditional Tailwind classes.

## Path aliases

Configured identically in both `app/vite.config.ts` (`resolve.alias`) and `app/tsconfig.json` (`compilerOptions.paths`) — update both together when adding new aliases:

- `@/*` → `app/src/mainview/*` (webview code, matches `components.json`'s `@/components`, `@/lib`, etc.)
- `@shared/*` → `app/src/shared/*` (types/contracts shared between the main process and the webview, e.g. the RPC schema)

## Styling

Tailwind CSS v4 — CSS-first configuration, no `tailwind.config.js`. Theme tokens (colors, radius) and the dark-mode variant live in `app/src/mainview/index.css` as CSS custom properties plus an `@theme inline` block, following shadcn's standard v4 token set.

## Window chrome

Frameless window: `titleBarStyle: "hiddenInset"` — native traffic lights (close/minimize/maximize), no visible title bar. There is no custom title bar/nav built yet. If one is added:

- Mark the draggable strip/background with the `electrobun-webkit-app-region-drag` class.
- Mark any interactive controls inside a draggable region (buttons, inputs, etc.) with `electrobun-webkit-app-region-no-drag` so clicks reach them instead of starting a window drag.
- Double-clicking the current draggable background toggles maximize/fill-screen (see `docs/ARCHITECTURE.md` for why this exists in place of native drag-to-tile).
