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
cd "$APP_DIR"
xcodegen generate
# Release keeps com.macdefier.app and the existing data/Keychain namespaces.
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
bash "$APP_DIR/scripts/install-app.sh" "$APP_DIR/build/DerivedData/Build/Products/Release/MacDefier.app"
