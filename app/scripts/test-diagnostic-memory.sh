#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "$script_dir/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/macdefier-diagnostic-memory.XXXXXX")"
trap 'rm -rf -- "$scratch_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$scratch_dir/clang-cache"
export SWIFT_MODULECACHE_PATH="$scratch_dir/swift-cache"

# These selected MonitorKit tests use synthetic counters and a fake sampler only.
swift test --package-path "$app_dir/MonitorKit" --scratch-path "$scratch_dir/build" \
  --filter 'MemorySamplingTests|SamplerLifecycleTests'
products_dir="$(swift build --package-path "$app_dir/MonitorKit" --scratch-path "$scratch_dir/build" --show-bin-path)"
mkdir -p "$scratch_dir/modules"
swiftc -parse-as-library -D CLEANUP_KIT_STUB -module-name CleanupKit -emit-module -emit-object \
  -emit-module-path "$scratch_dir/modules/CleanupKit.swiftmodule" \
  "$script_dir/diagnostic-memory-smoke/Fixture.swift" -o "$scratch_dir/modules/CleanupKit.o"
swiftc -parse-as-library -I "$scratch_dir/modules" -I "$products_dir" -L "$products_dir" -lMonitorKit \
  "$scratch_dir/modules/CleanupKit.o" \
  "$app_dir/MacDefier/Diagnostic/DiagnosticScore.swift" \
  "$app_dir/MacDefier/Diagnostic/DiagnosticScanEngine.swift" \
  "$app_dir/MacDefier/Diagnostic/DiagnosticScanService.swift" \
  "$app_dir/MacDefier/Diagnostic/DiagnosticScanStore.swift" \
  "$script_dir/diagnostic-memory-smoke/Fixture.swift" \
  "$script_dir/DiagnosticMemorySmokeMain.swift" -o "$scratch_dir/diagnostic-memory-smoke"
"$scratch_dir/diagnostic-memory-smoke"
