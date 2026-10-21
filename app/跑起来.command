#!/bin/bash
set -u
set -o pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$APP_DIR/build/DerivedData/Build/Products/Debug/MacDefier-Dev.app"
LOG="/tmp/macdefier_rebuild.log"
{
  echo "=== $(date) start via 跑起来.command ==="
  # 先 TERM 让正在清理/写盘的进程收尾，没退再 KILL
  pkill -x MacDefier-Dev 2>/dev/null || true
  sleep 0.5
  pkill -9 -x MacDefier-Dev 2>/dev/null || true
  cd "$APP_DIR" || exit 1
  if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate || { echo "xcodegen failed"; exit 1; }
  fi
  # 必须指定 -project：app/ 下出现多个 *.xcodeproj 时裸 -scheme 直接报错
  xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Debug \
    -derivedDataPath build/DerivedData \
    -destination 'platform=macOS' build \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
  BUILD_RC=$?
  if [[ $BUILD_RC -ne 0 ]]; then
    echo "xcodebuild failed rc=$BUILD_RC — 不启动旧包，先修上面的构建错误"
    exit "$BUILD_RC"
  fi
  open "$APP"
  sleep 1
  pgrep -lf MacDefier-Dev || true
  echo "=== $(date) done ==="
} 2>&1 | tee "$LOG"
