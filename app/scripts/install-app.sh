#!/bin/bash
# Install only com.macdefier.app → /Applications/MacDefier.app.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIFECYCLE="$APP_DIR/scripts/single_app_build.py"
if [[ "${SINGLE_APP_PRODUCT:-}" != MacDefier ]]; then
  exec python3 "$LIFECYCLE" run /bin/bash "$0" "$@"
fi
SRC="${1:-$APP_DIR/build/DerivedData/Build/Products/Release/MacDefier.app}"
[[ -d "$SRC" && ! -L "$SRC" ]] || { echo "Missing Release app: $SRC" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")" == com.macdefier.app ]] \
  || { echo "Rebuild Release: separate Dev identity is no longer installed." >&2; exit 1; }
STAGE="$SINGLE_APP_WORK/install/MacDefier.app"
mkdir -p "$(dirname "$STAGE")"
ditto "$SRC" "$STAGE"
# Signed distribution apps retain their signature and entitlements unchanged.
# Unsigned local Release builds are signed only in this job's private staging.
if ! codesign --verify --deep --strict "$STAGE" 2>/dev/null; then
  # Linker-produced local Mach-O files can already carry an ad-hoc signature.
  # Only a confirmed build output may be signed here; invalid external packages
  # are rejected instead of being silently re-signed.
  python3 "$LIFECYCLE" check-build-source "$SRC" || {
    echo "Invalid external signature; use a verified package or a local Release build." >&2
    exit 1
  }
  SIGN_ID="${MACDEFIER_SIGN_ID:--}"
  if ! security find-identity -v -p codesigning | grep -F "$SIGN_ID" >/dev/null; then
    SIGN_ID="-"
  fi
  xattr -cr "$STAGE"
  # Preserve Sparkle's nested entitlements; the privileged helper gets its own
  # signing identifier and no inherited main-app entitlements.
  while IFS= read -r -d '' bin; do
    [[ "$bin" != "$STAGE/Contents/MacOS/MacDefier" ]] || continue
    [[ "$(file -b "$bin")" == *Mach-O* ]] || continue
    if [[ "$bin" == "$STAGE/Contents/MacOS/MacDefier-UninstallHelper" ]]; then
      codesign --force --options runtime --identifier com.macdefier.app.uninstall-helper --sign "$SIGN_ID" "$bin"
    else
      codesign --force --options runtime --preserve-metadata=entitlements --sign "$SIGN_ID" "$bin"
    fi
  done < <(find "$STAGE/Contents" -type f \( -perm -111 -o -name '*.dylib' \) -print0)
  while IFS= read -r -d '' bundle; do
    codesign --force --options runtime --preserve-metadata=entitlements --sign "$SIGN_ID" "$bundle"
  done < <(find "$STAGE/Contents" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' \) -print0)
  codesign --force --options runtime --entitlements "$APP_DIR/MacDefier/MacDefier.entitlements" --sign "$SIGN_ID" "$STAGE"
fi
codesign --verify --deep --strict "$STAGE"
python3 "$LIFECYCLE" install "$STAGE" "${@:2}"
python3 "$LIFECYCLE" consume "$SRC"
echo "Installed → /Applications/MacDefier.app"
