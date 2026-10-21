#!/bin/bash
# Optional WindowServer smoke test; no real MacDefier service or executor is linked.
# Uses a transparent, non-activating window and exits within 15 s at runtime.
# Not run by headless CI. Logs and a fixture screenshot stay in the printed temp dir.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/MacDefier-layout-smoke.XXXXXX")"
echo "Layout smoke evidence: $scratch"
ruby "$script_dir/cleanup-layout-smoke/generate.rb" "$scratch"
nice -n 10 xcrun swiftc -swift-version 5 -Onone -g -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "${MACDEFIER_UI_MODULE_CACHE:-$scratch/module-cache}" \
  "$scratch/GeneratedProbe.swift" "$script_dir/cleanup-layout-smoke/Main.swift" \
  -o "$scratch/layout-probe"
nice -n 10 "$scratch/layout-probe" 2>&1 | tee "$scratch/result.log"
