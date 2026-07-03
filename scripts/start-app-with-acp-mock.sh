#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR/app"
exec env LEVEL5_USE_ACP_MOCK=1 bun run dev:hmr
