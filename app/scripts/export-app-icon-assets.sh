#!/bin/bash
# Rebuild legacy Mac icon silhouettes from existing code-rendered masters only.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/MacDefier-icon-assets.XXXXXX")"
echo "Icon asset evidence: $scratch"
nice -n 10 xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$scratch/module-cache" \
  "$repo_dir/app/MacDefier/MacAppIconArtwork.swift" "$script_dir/AppIconAssetsMain.swift" \
  -o "$scratch/app-icon-assets"
"$scratch/app-icon-assets" "$repo_dir" | tee "$scratch/result.log"
