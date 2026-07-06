#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_FILE="$ROOT_DIR/native/macos/window-effects.mm"
OUT_FILE="$ROOT_DIR/src/bun/libMacWindowEffects.dylib"

if [[ "$(uname -s)" != "Darwin" ]]; then
	mkdir -p "$(dirname "$OUT_FILE")"
	: >"$OUT_FILE"
	echo "Not on macOS: wrote an empty placeholder native effects dylib: $OUT_FILE"
	exit 0
fi

if [[ ! -f "$SRC_FILE" ]]; then
	echo "Missing source file: $SRC_FILE" >&2
	exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"
xcrun clang++ -dynamiclib -fobjc-arc -framework Cocoa "$SRC_FILE" -o "$OUT_FILE"
echo "Built native macOS window effects: $OUT_FILE"

if [[ "${ELECTROBUN_CODESIGN:-}" == "true" ]]; then
	if [[ -z "${ELECTROBUN_DEVELOPER_ID:-}" ]]; then
		echo "ELECTROBUN_CODESIGN=true requires ELECTROBUN_DEVELOPER_ID to sign $OUT_FILE" >&2
		exit 1
	fi

	codesign --force --options runtime --timestamp --sign "$ELECTROBUN_DEVELOPER_ID" "$OUT_FILE"
	echo "Signed native macOS window effects: $OUT_FILE"
fi
