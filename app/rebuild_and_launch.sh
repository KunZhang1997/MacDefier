#!/bin/bash
# Build the production identity and replace the one local installation.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
LIFECYCLE="$APP_DIR/scripts/single_app_build.py"
if [[ "${1:-}" == --self-test ]]; then
  exec python3 -B -m unittest discover -s "$APP_DIR/scripts/tests" -p test_single_app_build.py
fi
if [[ "${SINGLE_APP_PRODUCT:-}" != MacDefier ]]; then
  exec python3 "$LIFECYCLE" run /bin/bash "$0" "$@"
fi
if [[ "$APP_DIR" == *"/Desktop/"* ]] || [[ "$APP_DIR" == *"Mobile Documents"* ]]; then
  WORK_APP="${MACDEFIER_BUILD_DIR:-$HOME/Library/Caches/MacDefier-build}"
  mkdir -p "$WORK_APP"
  [[ -f "$WORK_APP/.macdefier-build-cache" ]] || printf '%s\n' 'macdefier-scratch-v1' > "$WORK_APP/.macdefier-build-cache"
  python3 "$LIFECYCLE" track "$WORK_APP"
  rsync -a --delete \
    --exclude '.macdefier-*' \
    --exclude '.build' --exclude 'build' --exclude 'DerivedData' \
    --exclude 'CleanupKit/.build' --exclude 'MonitorKit/.build' \
    --exclude 'PetArchiveKit/.build' --exclude 'UninstallHelperKit/.build' \
    "$APP_DIR/" "$WORK_APP/"
else
  WORK_APP="$APP_DIR"
fi
cd "$WORK_APP"
xcodegen generate
# Release keeps com.macdefier.app and the existing data/Keychain namespaces.
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
bash "$APP_DIR/scripts/install-app.sh" "$WORK_APP/build/DerivedData/Build/Products/Release/MacDefier.app"
