#!/bin/bash
# Optional local WindowServer test. Only fake state and selection code are linked.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/MacDefier-selection-ui.XXXXXX")"
echo "Selection UI smoke evidence: $scratch"
ruby "$script_dir/selection-ui-smoke/bulk-generate.rb" "$scratch" | tee "$scratch/bulk-extraction.log"
nice -n 10 xcrun swiftc -swift-version 5 -Onone -g -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "${MACDEFIER_UI_MODULE_CACHE:-$scratch/module-cache}" \
  "$scratch/BulkExtracted.swift" "$script_dir/selection-ui-smoke/BulkMain.swift" \
  -o "$scratch/selection-bulk-smoke"
nice -n 10 "$scratch/selection-bulk-smoke" 2>&1 | tee "$scratch/bulk-result.log"
ruby "$script_dir/selection-ui-smoke/generate.rb" "$scratch"
nice -n 10 xcrun swiftc -swift-version 5 -Onone -g -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "${MACDEFIER_UI_MODULE_CACHE:-$scratch/module-cache}" \
  "$scratch/Checkbox.swift" "$script_dir/selection-ui-smoke/Main.swift" \
  -o "$scratch/selection-ui-smoke"
nice -n 10 "$scratch/selection-ui-smoke" 2>&1 | tee "$scratch/result.log"
