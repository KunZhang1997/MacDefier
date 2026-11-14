#!/bin/bash
# Double-click entry: delegates to single-app Release rebuild & in-place install.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
/bin/bash "$APP_DIR/rebuild_and_launch.sh" "$@" 2>&1 | tee /tmp/macdefier_rebuild.log
