#!/bin/bash
# Install Debug build → /Applications/MacDefier-Dev.app (isolated from release).
# Bundle ID should be com.macdefier.app.dev when built with Debug settings.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  if [[ -d "$APP_DIR/build/DerivedData/Build/Products/Debug/MacDefier-Dev.app" ]]; then
    SRC="$APP_DIR/build/DerivedData/Build/Products/Debug/MacDefier-Dev.app"
  elif [[ -d "$APP_DIR/build/DerivedData/Build/Products/Debug/MacDefier.app" ]]; then
    SRC="$APP_DIR/build/DerivedData/Build/Products/Debug/MacDefier.app"
  else
    SRC="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/MacDefier-*/Build/Products/Debug/MacDefier*.app 2>/dev/null | head -1 || true)"
  fi
fi
[[ -n "$SRC" && -d "$SRC" ]] || { echo "No Debug MacDefier build found. Build Debug first."; exit 1; }

SIGN_ID="${MACDEFIER_SIGN_ID:--}"
DEST="/Applications/MacDefier-Dev.app"
STAGE="${TMPDIR:-/tmp}/MacDefier-Dev.app.install"

echo "Source: $SRC"
echo "Dest:   $DEST (never overwrites /Applications/MacDefier.app)"
echo "Sign:   $SIGN_ID"

pkill -x MacDefier-Dev 2>/dev/null || true
# Dev install is isolated; never terminate the notarized production app.
sleep 0.3

rm -rf "$STAGE"
ditto "$SRC" "$STAGE"
xattr -cr "$STAGE" 2>/dev/null || true
find "$STAGE" -name '._*' -delete 2>/dev/null || true

if security find-identity -v -p codesigning | grep -F "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --deep --options runtime --sign "$SIGN_ID" "$STAGE"
else
  echo "WARN: identity not found, ad-hoc (Keychain may prompt)."
  codesign --force --deep --sign - "$STAGE"
fi

rm -rf "$DEST"
ditto "$STAGE" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
if security find-identity -v -p codesigning | grep -F "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --deep --options runtime --sign "$SIGN_ID" "$DEST"
else
  codesign --force --deep --sign - "$DEST"
fi

codesign -dv --verbose=2 "$DEST" 2>&1 | head -15
open "$DEST"
echo "Installed → $DEST (release MacDefier.app untouched)"
