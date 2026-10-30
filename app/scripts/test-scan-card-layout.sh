#!/bin/bash
# Real shared SwiftUI card layout. Invisible test windows; no desktop input or scans.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
scan_card_scratch="$(mktemp -d /private/tmp/macdefier-scan-card.XXXXXX)"
trap 'rm -rf -- "$scan_card_scratch"' EXIT
python3 - "$script_dir/.." "$script_dir/scan-card-layout-smoke/Main.swift" "$scan_card_scratch/Probe.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
theme = (root / 'MacDefier/Theme.swift').read_text()
tokens = theme[:theme.index('enum AppAppearance:')]
colors = theme[theme.index('extension Color {'):theme.index('// MARK: - Shared chrome')]
journey = (root / 'CleanupKit/Sources/CleanupKit/ScanJourney.swift').read_text()
card = (root / 'MacDefier/Views/MDScanActivityCard.swift').read_text().replace('import CleanupKit\n', '')
Path(sys.argv[3]).write_text(tokens + colors + '\n' + journey + '\n' + card + '\n' + Path(sys.argv[2]).read_text())
PY
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$scan_card_scratch/module-cache" \
    "$scan_card_scratch/Probe.swift" -o "$scan_card_scratch/probe"
"$scan_card_scratch/probe"
