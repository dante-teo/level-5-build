#!/usr/bin/env bash
set -euo pipefail
set -m

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
ACP_DIR="$ROOT_DIR/acp-mock-server"
STATE_PATH="${ACP_MOCK_STATE_PATH:-$ACP_DIR/.mock-acp-state.json}"

cleanup() {
	trap - EXIT INT TERM
	if [[ -n "${APP_PID:-}" ]]; then kill -TERM "-$APP_PID" 2>/dev/null || kill -TERM "$APP_PID" 2>/dev/null || true; fi
	if [[ -n "${ACP_PID:-}" ]]; then kill -TERM "-$ACP_PID" 2>/dev/null || kill -TERM "$ACP_PID" 2>/dev/null || true; fi
	sleep 1
	if [[ -n "${APP_PID:-}" ]]; then kill -KILL "-$APP_PID" 2>/dev/null || kill -KILL "$APP_PID" 2>/dev/null || true; fi
	if [[ -n "${ACP_PID:-}" ]]; then kill -KILL "-$ACP_PID" 2>/dev/null || kill -KILL "$ACP_PID" 2>/dev/null || true; fi
	wait "$APP_PID" "$ACP_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

echo "Starting ACP mock server..."
(
	cd "$ACP_DIR"
	exec env ACP_MOCK_KEEPALIVE=1 ACP_MOCK_STATE_PATH="$STATE_PATH" ./start.sh
) &
ACP_PID=$!

echo "Starting Level5 Build app..."
(
	cd "$APP_DIR"
	exec bun run dev:hmr
) &
APP_PID=$!

cat <<EOF

Manual test processes are running.

ACP mock server:
  cwd:     $ACP_DIR
  command: ./start.sh
  state:   $STATE_PATH

Desktop app:
  cwd:     $APP_DIR
  command: bun run dev:hmr

Press Ctrl-C to stop both.
EOF

while kill -0 "$APP_PID" 2>/dev/null && kill -0 "$ACP_PID" 2>/dev/null; do
	sleep 1
done
