#!/usr/bin/env bash
# CI：CleanupKit / PetArchiveKit / MonitorKit / AI 回归 + Debug / Release 构建。
# 任何一步失败即退出；发布前必跑。
# Vault 在 iCloud Desktop 时，CleanupKit swift test 在缓存目录跑，避免 NSFileCoordinator 卡死。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"
CK_SRC="$APP_DIR/CleanupKit"
CK_CACHE="${MACDEFIER_CK_TEST_DIR:-$HOME/Library/Caches/MacDefier-CleanupKit-test}"
BUILD_CACHE="${MACDEFIER_BUILD_DIR:-$HOME/Library/Caches/MacDefier-build}"

assert_safe_scratch() {
  local requested="$1" label="$2" marker="$3"
  case "$requested" in
    "$HOME/Library/Caches/MacDefier-"*|"$HOME/Library/Caches/MacDefier/"*|/private/tmp/MacDefier-*|/tmp/MacDefier-*) ;;
    *) echo "拒绝不安全的 $label 路径：$requested" >&2; exit 2 ;;
  esac
  case "$requested" in
    *"/../"*|*"/.."|*"/./"*|*"//"*) echo "拒绝未规范化的 $label 路径：$requested" >&2; exit 2 ;;
  esac
  local parent="$(dirname "$requested")" leaf="$(basename "$requested")"
  [[ -d "$parent" ]] || mkdir -p "$parent"
  local path="$(cd "$parent" && pwd -P)/$leaf"
  [[ ! -L "$requested" ]] || { echo "拒绝符号链接 $label：$requested" >&2; exit 2; }
  [[ ! -e "$path" || -d "$path" ]] || { echo "$label 不是目录：$path" >&2; exit 2; }
  for broad in / "$HOME" "$ROOT" "$APP_DIR" "$CK_SRC"; do
    [[ "$path" != "$broad" && "$broad" != "$path/"* ]] \
      || { echo "拒绝项目/宽泛 $label 路径：$path" >&2; exit 2; }
  done
  [[ "$path" != "$ROOT/"* && "$path" != "$APP_DIR/"* && "$path" != "$CK_SRC/"* ]] \
    || { echo "拒绝项目内 $label 路径：$path" >&2; exit 2; }
  local cacheRoot="$(cd "$HOME/Library/Caches" && pwd -P)"
  [[ "$path" == "$cacheRoot/MacDefier-"* || "$path" == "$cacheRoot/MacDefier/"* \
      || "$path" == /private/tmp/MacDefier-* || "$path" == /tmp/MacDefier-* ]] \
    || { echo "拒绝 canonical 逃逸的 $label 路径：$path" >&2; exit 2; }
  mkdir -p "$path"
  local markerPath="$path/.macdefier-$marker"
  if [[ -f "$markerPath" ]]; then
    [[ "$(<"$markerPath")" == "macdefier-scratch-v1" ]] \
      || { echo "$label marker 无效：$markerPath" >&2; exit 2; }
  elif [[ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf '%s\n' 'macdefier-scratch-v1' > "$markerPath"
  else
    echo "拒绝复用没有 marker 的非空 $label：$path" >&2; exit 2
  fi
  printf '%s\n' "$path"
}

CK_CACHE="$(assert_safe_scratch "$CK_CACHE" "CleanupKit test cache" cleanup-test)"
BUILD_CACHE="$(assert_safe_scratch "$BUILD_CACHE" "build cache" build-cache)"

echo "==> [1/7] xcodegen (cache tree if iCloud Desktop)"
# Prefer building app from non-iCloud cache when source is under Desktop/iCloud
if [[ "$APP_DIR" == *"/Desktop/"* ]] || [[ "$APP_DIR" == *"Mobile Documents"* ]]; then
  rsync -a --delete \
    --exclude '.macdefier-*' \
    --exclude '.build' --exclude 'build' --exclude 'DerivedData' \
    --exclude 'CleanupKit/.build' --exclude 'MonitorKit/.build' \
    "$APP_DIR/" "$BUILD_CACHE/"
  WORK_APP="$BUILD_CACHE"
else
  WORK_APP="$APP_DIR"
fi
cd "$WORK_APP"
xcodegen generate

echo "==> [2/7] CleanupKit 单测（PathGate 删除安全 / 匹配引擎）"
rsync -a --delete \
  --exclude '.macdefier-*' \
  --exclude '.build' --exclude 'build' \
  "$CK_SRC/" "$CK_CACHE/"
# Keep WORK_APP CleanupKit in sync if using cache tree
if [[ "$WORK_APP" != "$APP_DIR" ]]; then
  rsync -a --delete --exclude '.build' --exclude '.macdefier-*' "$CK_SRC/" "$WORK_APP/CleanupKit/"
fi
# XCTest failures can still yield EXIT 0 when Swift Testing reports "0 tests".
# Parse the summary and fail hard on any failure/error.
set +e
TEST_LOG="$(mktemp -t macdefier-ck-test.XXXXXX)"
(cd "$CK_CACHE" && swift test 2>&1 | tee "$TEST_LOG")
TEST_EC=$?
set -e
if grep -Eiq 'failed \(| error: |XCTAssert[^[:space:]]* failed|Test Case .* failed| Testhad failures|failures before|failed \([1-9]' "$TEST_LOG"; then
  echo "==> CleanupKit tests reported failures (see log)"
  rm -f "$TEST_LOG"
  exit 1
fi
# Also require an explicit suite summary with 0 failures when present
if grep -E 'Executed [0-9]+ tests?' "$TEST_LOG" | tail -5 | grep -Eq 'with [1-9][0-9]* failure'; then
  echo "==> CleanupKit XCTest summary has failures"
  rm -f "$TEST_LOG"
  exit 1
fi
if grep -Eiq '^error: |Building for debugging.*error:|Test Suite .* failed' "$TEST_LOG"; then
  echo "==> CleanupKit test build/run error"
  rm -f "$TEST_LOG"
  exit 1
fi
# If swift test itself failed and we didn't already catch text, still fail
if [[ "$TEST_EC" -ne 0 ]]; then
  echo "==> swift test exit $TEST_EC (earlier passing suites cannot override a later failure)"
  rm -f "$TEST_LOG"
  exit 1
fi
rm -f "$TEST_LOG"

echo "==> [3/7] PetArchiveKit 单测（M10 pet zip symlink/slip）"
# WORK_APP 已含 PetArchiveKit + Vendor/ZIPFoundation（Package path: ../Vendor/ZIPFoundation）
set +e
PA_LOG="$(mktemp -t macdefier-pa-test.XXXXXX)"
(cd "$WORK_APP/PetArchiveKit" && swift test 2>&1 | tee "$PA_LOG")
PA_EC=$?
set -e
if grep -Eiq 'failed \(| error: |XCTAssert[^[:space:]]* failed|Test Case .* failed|failures before|failed \([1-9]' "$PA_LOG"; then
  echo "==> PetArchiveKit tests reported failures (see log)"
  rm -f "$PA_LOG"
  exit 1
fi
if [[ "$PA_EC" -ne 0 ]]; then
  echo "==> PetArchiveKit swift test exit $PA_EC"
  rm -f "$PA_LOG"
  exit 1
fi
rm -f "$PA_LOG"

echo "==> [4/7] MonitorKit 单测（进程退出 / 超时 / Pipe / 采样生命周期）"
(cd "$WORK_APP/MonitorKit" && swift test)

echo "==> [5/7] AI 与诊断回归（端点 / 重定向 / 凭据隔离 / 采样有效性）"
bash "$WORK_APP/scripts/test-ai-endpoint-policy.sh"
bash "$WORK_APP/scripts/test-ai-request-transport.sh"
bash "$WORK_APP/scripts/test-ai-profile-isolation.sh"
bash "$WORK_APP/scripts/test-diagnostic-memory.sh"
bash "$WORK_APP/scripts/test-disk-treemap.sh"

echo "==> [6/7] App 全量构建（Debug）"
cd "$WORK_APP"
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Debug \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

echo "==> [7/7] App 全量构建（Release，不签名、不分发）"
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'generic/platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

echo "==> CI OK：单测 + 构建全部通过"
