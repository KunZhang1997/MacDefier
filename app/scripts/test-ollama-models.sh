#!/usr/bin/env bash
# Exercise shipped model management with loopback fixtures; no real model download.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/MacDefier-OllamaSmoke.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library -module-cache-path "$TEST_DIR/module-cache" \
  "$APP_DIR/MacDefier/AI/AIEndpointPolicy.swift" \
  "$APP_DIR/MacDefier/AI/OllamaModelManager.swift" \
  "$APP_DIR/MacDefier/AI/OllamaRuntime.swift" \
  "$SCRIPT_DIR/OllamaModelSmokeMain.swift" \
  -framework Network -framework Combine -o "$TEST_DIR/smoke"
"$TEST_DIR/smoke"
