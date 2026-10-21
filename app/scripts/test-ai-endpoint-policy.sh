#!/usr/bin/env bash
# Compile + run M08-1 AIEndpointPolicy smoke tests against SHIPPED source.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${TMPDIR:-/tmp}/MacDefier-AIEndpointPolicySmoke-$$"
# No -parse-as-library: SmokeMain uses top-level entry; policy is pure types.
swiftc \
  "$APP_DIR/MacDefier/AI/AIEndpointPolicy.swift" \
  "$SCRIPT_DIR/AIEndpointPolicySmokeMain.swift" \
  -framework Network \
  -o "$OUT"
"$OUT"
rm -f "$OUT"
