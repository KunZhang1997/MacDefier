#!/usr/bin/env bash
# Compile the shipped, pure geometry source without starting the app or scanning a disk.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/MacDefier-DiskTreemapSmoke.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
swiftc -parse-as-library \
  -module-cache-path "$TEST_DIR/module-cache" \
  "$APP_DIR/MacDefier/Views/DiskTreemapLayout.swift" \
  "$SCRIPT_DIR/DiskTreemapSmokeMain.swift" \
  -o "$TEST_DIR/DiskTreemapSmoke"
"$TEST_DIR/DiskTreemapSmoke"
