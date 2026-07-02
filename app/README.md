# app

An Electrobun desktop app: Bun + a native OS webview (no bundled Chromium/CEF), React 18, Vite 6 for the webview bundle, Tailwind CSS v4, and a manually-configured shadcn/ui foundation.

Currently the app is an early desktop AI coding agent shell: a single frameless window showing a full-bleed background image, with the runtime, RPC, styling, and component foundation in place for the product workspace.

See also:

- `../docs/PRODUCT.md` for product direction
- `../docs/ARCHITECTURE.md` for runtime architecture
- `../docs/DESIGN.md` for visual and interaction rules

## Getting Started

```bash
# Install dependencies
bun install

# Build the webview once, then launch Electrobun against bundled assets
bun run start

# Development with HMR (recommended)
bun run dev:hmr

# Watch Electrobun-side files without rebuilding the Vite webview first
bun run dev

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

1. Electrobun starts in watch mode
2. The app loads from `views://mainview/index.html`
3. Bundled webview assets must already exist; use `bun run start` to rebuild them before launching
4. Use this mostly for Bun/main-process changes, not React UI iteration

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
