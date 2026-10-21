#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "$script_dir/.." && pwd)"
geometry_scratch="$(mktemp -d "/private/tmp/macdefier-pet-geometry.XXXXXX")"
trap 'rm -rf -- "$geometry_scratch"' EXIT
ruby -e '
  source = File.read(ARGV[0])
  start = source.index("enum PetOverlayGeometry") or abort "Missing geometry source"
  tests = File.read(ARGV[1])
  File.write(ARGV[2], "import Foundation\nimport CoreGraphics\n" + source[start..] + "\n" + tests)
' "$app_dir/MacDefier/Views/Pet/PetTypes.swift" "$script_dir/pet-overlay-geometry-smoke/Main.swift" "$geometry_scratch/main.swift"
xcrun swift "$geometry_scratch/main.swift"
