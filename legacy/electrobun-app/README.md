# Level5 Build Electrobun Reference App

This directory contains the retired Electrobun proof of concept for Level5 Build. It is kept intact as reference-only migration material while the native macOS app takes over `../../app/`.

The app remains buildable from this directory when historical behavior needs to be inspected:

```bash
pnpm install
pnpm run build:web
pnpm run typecheck
pnpm run test
```

Do not add new product work here unless the task explicitly targets the legacy reference app.
