#!/usr/bin/env bash
# Compile shipped transport; exercise real HTTP using loopback + fake data only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/MacDefier-AIRequestTransportSmoke.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/module-cache" \
  "$APP_DIR/MacDefier/AI/AIRequestTransport.swift" \
  "$SCRIPT_DIR/AIRequestTransportSmokeMain.swift" \
  -framework Network \
  -o "$TEST_DIR/smoke"
"$TEST_DIR/smoke"
