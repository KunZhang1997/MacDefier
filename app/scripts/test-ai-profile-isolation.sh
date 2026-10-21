#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/MacDefier-AIProfileIsolation.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -module-cache-path "$SCRATCH/module-cache" \
  "$APP_DIR/MacDefier/AI/AISettings.swift" \
  "$APP_DIR/MacDefier/AI/AIEndpointPolicy.swift" \
  "$SCRIPT_DIR/AIProfileIsolationSmokeMain.swift" \
  -framework Network -framework Security -o "$SCRATCH/probe"
"$SCRATCH/probe"
