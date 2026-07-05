#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 MAJOR.MINOR.PATCH[-PRERELEASE]" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

version="$1"
project_file="app/project.yml"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
  echo "error: invalid version '$version'" >&2
  usage
  exit 2
fi

if [[ ! -f "$project_file" ]]; then
  echo "error: expected $project_file to exist" >&2
  exit 1
fi

current_marketing_version="$(awk -F: '/^[[:space:]]+MARKETING_VERSION:/ { gsub(/[ "]/, "", $2); print $2; exit }' "$project_file")"
current_project_version="$(awk -F: '/^[[:space:]]+CURRENT_PROJECT_VERSION:/ { gsub(/[ "]/, "", $2); print $2; exit }' "$project_file")"

if [[ -z "$current_marketing_version" || -z "$current_project_version" ]]; then
  echo "error: could not read MARKETING_VERSION and CURRENT_PROJECT_VERSION from $project_file" >&2
  exit 1
fi

if [[ ! "$current_project_version" =~ ^[0-9]+$ ]]; then
  echo "error: CURRENT_PROJECT_VERSION is not numeric: $current_project_version" >&2
  exit 1
fi

next_project_version="$current_project_version"
if [[ "$version" != "$current_marketing_version" ]]; then
  next_project_version="$((current_project_version + 1))"
fi

tmp_file="$(mktemp "${TMPDIR:-/tmp}/level5-project-yml.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

awk -v marketing_version="$version" -v project_version="$next_project_version" '
  /^[[:space:]]+MARKETING_VERSION:/ {
    sub(/MARKETING_VERSION: .*/, "MARKETING_VERSION: \"" marketing_version "\"")
  }
  /^[[:space:]]+CURRENT_PROJECT_VERSION:/ {
    sub(/CURRENT_PROJECT_VERSION: .*/, "CURRENT_PROJECT_VERSION: \"" project_version "\"")
  }
  { print }
' "$project_file" > "$tmp_file"

mv "$tmp_file" "$project_file"
trap - EXIT

echo "Updated $project_file: MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$next_project_version"
