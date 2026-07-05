#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${LEVEL5_ACP_MOCK_HOST:-127.0.0.1}"
PORT="${LEVEL5_ACP_MOCK_PORT:-58945}"
STATE_PATH="${ACP_MOCK_STATE_PATH:-$HOME/.level5-build/acp-mock-state.json}"
WAIT_FOR_APP=0

if [[ "$MODE" == "run" ]]; then
  WAIT_FOR_APP=1
fi

mkdir -p "$(dirname "$STATE_PATH")"

mock_pid=""
cleanup() {
  if [[ -n "$mock_pid" ]] && kill -0 "$mock_pid" >/dev/null 2>&1; then
    kill "$mock_pid" >/dev/null 2>&1 || true
    wait "$mock_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

ACP_MOCK_TCP_HOST="$HOST" \
  ACP_MOCK_TCP_PORT="$PORT" \
  ACP_MOCK_STATE_PATH="$STATE_PATH" \
  ACP_MOCK_LOG="${ACP_MOCK_LOG:-info}" \
  "$ROOT_DIR/acp-mock-server/start-tcp.sh" &
mock_pid=$!

for _ in {1..80}; do
  if nc -z "$HOST" "$PORT" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$mock_pid" >/dev/null 2>&1; then
    echo "ACP mock server exited before accepting connections" >&2
    wait "$mock_pid" || true
    exit 1
  fi
  sleep 0.1
done

if ! nc -z "$HOST" "$PORT" >/dev/null 2>&1; then
  echo "ACP mock server did not start on $HOST:$PORT" >&2
  exit 1
fi

LEVEL5_USE_ACP_MOCK=1 \
  LEVEL5_ACP_MOCK_HOST="$HOST" \
  LEVEL5_ACP_MOCK_PORT="$PORT" \
  LEVEL5_WAIT_FOR_APP="$WAIT_FOR_APP" \
  "$ROOT_DIR/script/build_and_run.sh" "$MODE"
