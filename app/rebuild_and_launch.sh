#!/bin/bash
# 指定唯一工程，避免 app/ 下多个 *.xcodeproj 导致 xcodebuild 失败
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$APP_DIR/build/DerivedData/Build/Products/Debug/MacDefier-Dev.app"
LOG="/tmp/macdefier_rebuild.log"
{
  echo "=== $(date) start ==="
  # 先 TERM 给清理/写盘收尾机会，没退再 KILL
  pkill -x MacDefier-Dev 2>/dev/null || true
  sleep 0.5
  pkill -9 -x MacDefier-Dev 2>/dev/null || true
  sleep 0.5
  cd "$APP_DIR"
  # 清掉 xcodegen 误生成/重复的平行工程（只保留 MacDefier.xcodeproj）
  rm -rf "MacDefier 2.xcodeproj" "MacDefier 3.xcodeproj" "MacDefier 4.xcodeproj" 2>/dev/null || true
  command -v xcodegen >/dev/null && xcodegen generate || true
  rm -rf "MacDefier 2.xcodeproj" "MacDefier 3.xcodeproj" "MacDefier 4.xcodeproj" 2>/dev/null || true
  xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Debug \
    -derivedDataPath build/DerivedData \
    -destination 'platform=macOS' build \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
  pkill -x MacDefier-Dev 2>/dev/null || true
  sleep 1
  open "$APP"
  sleep 1
  pgrep -lf "MacDefier-Dev.app" || echo "not running"
  echo "=== $(date) done ==="
} >"$LOG" 2>&1 || { echo "构建失败，日志如下："; cat "$LOG"; exit 1; }
cat "$LOG"
