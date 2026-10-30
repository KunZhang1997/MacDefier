#!/bin/bash
set -euo pipefail
case "${PRODUCT_BUNDLE_IDENTIFIER:?}" in
  com.macdefier.app) service=com.macdefier.app.uninstall-helper; other=com.macdefier.app.dev.uninstall-helper ;;
  com.macdefier.app.dev) service=com.macdefier.app.dev.uninstall-helper; other=com.macdefier.app.uninstall-helper ;;
  *) echo 'Unexpected MacDefier identity; refusing helper embedding.' >&2; exit 1 ;;
esac
destination="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Library/LaunchDaemons"
case "$destination" in
  */MacDefier.app/Contents/Library/LaunchDaemons|*/MacDefier-Dev.app/Contents/Library/LaunchDaemons) ;;
  *) echo 'Unexpected build product path.' >&2; exit 1 ;;
esac
mkdir -p "$destination"
# Only the known opposite-configuration definition in this build product.
if [[ -f "$destination/$other.plist" && ! -L "$destination/$other.plist" ]]; then
  rm "$destination/$other.plist"
fi
cp "${SRCROOT:?}/UninstallHelper/LaunchDaemons/$service.plist" "$destination/$service.plist"
plutil -lint "$destination/$service.plist"
