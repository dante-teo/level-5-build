# app

An Electrobun desktop app: Bun + a native OS webview (no bundled Chromium/CEF), React 18, Vite 6 for the webview bundle, Tailwind CSS v4, and a manually-configured shadcn/ui foundation.

Currently the app is an empty shell: a single frameless window showing a full-bleed background image.

## Getting Started

```bash
# Install dependencies
bun install

# Development without HMR (uses bundled assets)
bun run dev

# Development with HMR (recommended)
bun run dev:hmr

# Build for production (bundles the webview, then builds the app)
bun run build
```

## How HMR Works

When you run `bun run dev:hmr`:

1. **Vite dev server** starts on `http://localhost:5173` with HMR enabled
2. **Electrobun** starts and detects the running Vite server
3. The app loads from the Vite dev server instead of bundled assets
4. Changes to React components update instantly without a full page reload

When you run `bun run dev` (without HMR):

1. Electrobun starts and loads from `views://mainview/index.html`
2. You need to rebuild (`bun run start`, which runs `vite build` first) to see changes

## Project Structure

```
├── src/
│   ├── bun/
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
- **Main process ⇄ webview calls**: add methods to the `AppRPC` type in `src/shared/rpc.ts`, implement the handler in `src/bun/index.ts`, call it from the webview via `electroview.rpc.request.<method>()`

## Known limitation: no native window-tiling on drag

Electrobun's window drag doesn't hook into the OS's native move loop, so dragging the window to the screen edges/top won't auto-snap/tile like a normal native window (tracked upstream: [blackboardsh/electrobun#395](https://github.com/blackboardsh/electrobun/issues/395)). As a stand-in, double-clicking the window background toggles maximize/fill-screen, via the `toggleMaximizeWindow` RPC method.
