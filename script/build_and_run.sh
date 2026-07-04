#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Level5 Build"
PRODUCT_NAME="Level5Build"
BUNDLE_ID="io.anvia.level5.build"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ASSET_CATALOG="$APP_DIR/Resources/Assets.xcassets"
ASSET_INFO_PLIST="$APP_CONTENTS/assetcatalog_generated_info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --package-path "$APP_DIR" --product "$PRODUCT_NAME"
BUILD_BINARY="$(swift build --package-path "$APP_DIR" --show-bin-path)/$PRODUCT_NAME"
BUILD_BIN_DIR="$(dirname "$BUILD_BINARY")"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -d "$ASSET_CATALOG" ]]; then
  xcrun actool "$ASSET_CATALOG" \
    --compile "$APP_RESOURCES" \
    --platform macosx \
    --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_INFO_PLIST" >/dev/null
fi

for resource_bundle in "$BUILD_BIN_DIR"/Level5Build_*.bundle; do
  if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$APP_BUNDLE/"
  fi
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.0</string>
  <key>CFBundleVersion</key>
  <string>0</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  if [[ "${LEVEL5_USE_ACP_MOCK:-0}" == "1" ]]; then
    LEVEL5_USE_ACP_MOCK=1 \
      LEVEL5_ACP_MOCK_HOST="${LEVEL5_ACP_MOCK_HOST:-127.0.0.1}" \
      LEVEL5_ACP_MOCK_PORT="${LEVEL5_ACP_MOCK_PORT:-58945}" \
      "$APP_BINARY" &
    app_pid=$!
    if [[ "${LEVEL5_WAIT_FOR_APP:-0}" == "1" ]]; then
      wait "$app_pid"
    fi
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
