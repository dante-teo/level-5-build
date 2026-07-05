#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 VERSION SHA256 URL" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

version="$1"
sha256="$2"
url="$3"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: Homebrew stable cask version must be MAJOR.MINOR.PATCH: $version" >&2
  exit 2
fi

if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: SHA-256 must be 64 lowercase hex characters" >&2
  exit 2
fi

case "$url" in
  https://github.com/*/releases/download/v"$version"/Level5-Build-v"$version"-macos-arm64.dmg) ;;
  *)
    echo "error: URL does not match the expected Level5 Build release artifact pattern" >&2
    exit 2
    ;;
esac

cat <<CASK
cask "level5-build" do
  version "$version"
  sha256 "$sha256"

  url "$url"
  name "Level5 Build"
  desc "Native macOS app for running Level5 agent sessions"
  homepage "https://github.com/dante-teo/level-5-build"

  depends_on arch: :arm64

  app "Level5 Build.app"
end
CASK
