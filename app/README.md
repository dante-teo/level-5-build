# Level5 Build

The Level5 Build desktop app: Bun + [Electrobun](https://blackboard.sh/electrobun) + React. See `docs/ARCHITECTURE.md` and `docs/DESIGN.md` at the repo root for architecture and design token details.

```bash
bun install
bun run typecheck
bun test
bun run build:web
```

Bun is used uniformly for both dependency installation and running (`bun install` populates `node_modules`; `bun run dev`, `bun run dev:mock`, and `bun test` all use Bun as the runtime).
